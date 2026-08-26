import Foundation
import FoundationModels
import Synchronization
import os

/// The logger ``RoutedSessionActor`` reports a turn's failed pre-discovery
/// seeding to (see ``RoutedSessionActor/primeDiscoveryIfConfigured(prompt:emit:)``).
///
/// Its own category rather than ``sessionRecordingLogger``'s, for the same
/// reason ``sessionCompactionLogger`` has one: what it reports is a priming
/// outcome, not a recording one. A failure is logged *and* surfaced as
/// ``SessionEvent/discoveryPrimingFailed(_:)`` — the log is for an operator
/// reading a session's console after the fact, the event for a host watching the
/// session live (see ``RoutedSession/streamSessionEvents()``, the route that
/// carries it on every turn including the ones that hand their caller a response
/// rather than a stream).
private let sessionPrimingLogger = makeModuleLogger(category: "DiscoveryPriming")

/// ``RoutedSessionActor``'s turn execution: the recorder-bracketed chokepoint
/// every generation funnels through, the queued-prompt turn and the composed
/// model-visible prompt a turn submits, the discovery priming and overflow
/// recovery wrapped around it, and the cancellation boundary the model call
/// itself runs inside.
extension RoutedSessionActor {
    /// Builds the closure that submits a turn's composed prompt to `backend`,
    /// honoring `grammar` when present — the if-let-grammar branch between
    /// the plain and grammar-guided `backend.respond(to:maxTokens:)` entry
    /// points that ``respond(to:maxTokens:)`` (a caller-supplied prompt) and
    /// ``dispatchNextPrompt()`` (a queue-sourced prompt) both need, so that
    /// branch lives in exactly one place regardless of where the turn's
    /// prompt came from.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, or
    ///     `nil` for an unguided turn.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to
    ///     use the underlying model's own default ceiling.
    /// - Returns: A closure that, given this turn's composed prompt, submits
    ///   it to `backend.respond` — following `grammar` when present.
    func respondBody(grammar: Grammar?, maxTokens: Int?) -> @Sendable (String) async throws -> String {
        guard let grammar else {
            return { composedPrompt in
                try await self.backend.respond(to: composedPrompt, maxTokens: maxTokens)
            }
        }
        return { composedPrompt in
            try await self.backend.respond(to: composedPrompt, following: grammar, maxTokens: maxTokens)
        }
    }

    /// The single recorder-bracketed generation chokepoint every public method
    /// funnels through.
    ///
    /// The whole bracket runs inside this session's ``turnLock`` and, nested
    /// inside that, the model's per-model ``RoutedModel/generationGate``, so two
    /// turns on one session can never interleave and concurrent generations on
    /// one model — including from forks that share the gate — queue in FIFO
    /// order rather than interleave. Inside the gates it first lazily records the session's
    /// first-line `session` meta event (once per session), drains ``outbox``
    /// and composes this turn's prompt (see below), then runs `body`, then
    /// snapshot-diffs ``backend``'s real transcript (see
    /// ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``) so what
    /// lands on disk mirrors the SDK's own `Transcript.Entry` values rather
    /// than a hand-built paraphrase of the prompt/response strings — on the
    /// success path and the throwing path alike, so a transcript always
    /// gains whatever the SDK durably appended for the turn. A throwing turn
    /// additionally gets a bodyless `.response`-kind close event carrying the
    /// turn's `ms`, so every failed turn still leaves a trace even when the
    /// SDK appended no `.response` entry of its own. On both exits, if the
    /// turn's diff produced no `.prompt`-kind partial for the drained events
    /// to attach to — nothing was durably delivered, so the events never
    /// actually rode any turn — they are re-queued onto ``outbox`` (see
    /// ``requeueUnattachedPendingEvents(events:)``) rather than lost, since
    /// ``SessionOutbox/drainForDispatch()`` already destructively removed
    /// them up front. Every event is routed to this session's
    /// ``recordingDirectory``, so the on-disk transcript tree mirrors the fork
    /// lineage; the single recorder stamps a globally monotonic `seq` at append.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, stamped
    ///     onto every event this turn appends.
    ///   - prompt: The caller's own prompt, before this turn's drain-on-turn
    ///     composition (see below).
    ///   - onEvent: A sink for this turn's derived ``SessionEvent``s, or
    ///     `nil` to skip event derivation entirely.
    ///   - body: The model work to run inside the bracket, given this turn's
    ///     composed prompt and returning the response text callers receive
    ///     (still returned directly; no longer the source of any recorded
    ///     event body).
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event.
    func generate(
        grammar: Grammar? = nil,
        prompt: String,
        onEvent: ((SessionEvent) -> Void)? = nil,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // Acquire both gates for the whole bracket, releasing them on every path
        // with a `defer` (the recording bracket stays in this actor's isolation
        // region, so the gated work is not sent across an isolation boundary as a
        // `withPermit` closure would be). `beginTurn()`/`endTurn()` pair exactly
        // like `withPermit`, so no permit can leak. A refusal throws before
        // either gate is touched, so the `defer` is installed only once there is
        // something to release.
        let turnId = try await beginTurn()
        defer { endTurn() }

        await recordSessionMetaIfNeeded()

        // Drain-on-turn: everything staged in `outbox` since the last turn is
        // folded into *this* turn's prompt, here inside the turn lock so a
        // drain never interleaves with a concurrent turn. This caller supplies
        // its own prompt directly, so only events are drained — never the
        // queued-prompt FIFO (see ``SessionOutbox/drainPendingEvents()``, as
        // opposed to ``SessionOutbox/drainForDispatch()``, which only
        // ``dispatchNextPrompt()`` uses): a prompt waiting in the queue is left
        // exactly where it is rather than silently dequeued and discarded by
        // an unrelated ad hoc turn. An empty outbox drains to an empty
        // `pendingEvents`, so ``composedPrompt(pendingEvents:prompt:)`` returns
        // `prompt` unchanged and ``attachingPendingEventSegments(events:to:)``
        // attaches nothing below — byte-identical to a session that never
        // used an outbox.
        let pendingEvents = await outbox.drainPendingEvents().map(\.event)
        return try await runTurn(
            grammar: grammar, turnId: turnId, promptId: nil, pendingEvents: pendingEvents,
            ownPrompt: prompt, onEvent: onEvent, body)
    }

    /// Composes a turn's own event sink with this session's session-scoped
    /// fan-out, so every event delivered through this sink reaches both routes.
    ///
    /// `onEvent` is the per-turn stream only ``streamEvents(to:maxTokens:)``
    /// hands its caller; the session-scoped route reaches a
    /// ``RoutedSession/streamSessionEvents()`` subscriber whichever entry point
    /// ran the turn — including ``respond(to:maxTokens:)`` and
    /// ``dispatchNextPrompt()``, which hand their caller a response rather than
    /// a stream. Composing the two here is what makes the session-scoped stream
    /// one merged feed of a session's lifecycle events, and it is why the
    /// returned sink is never `nil`: every turn derives its events now, whoever
    /// started it.
    ///
    /// The live text increments — ``SessionEvent/textDelta(_:)`` and
    /// ``SessionEvent/textReset`` — do **not** travel through this sink. They
    /// are yielded straight to the per-turn continuation by
    /// ``streamGeneratingBody(composedPrompt:maxTokens:into:wrapFragment:)``
    /// and deliberately never reach the session-scoped feed — see
    /// ``RoutedSession/streamSessionEvents()`` for that exclusion and its
    /// reason.
    ///
    /// - Parameter onEvent: This turn's own sink, or `nil` when the entry point
    ///   that started the turn has no stream of its own.
    /// - Returns: A sink that delivers to `onEvent` when there is one, and to
    ///   every live session-scoped subscription always.
    private func turnEventSink(_ onEvent: ((SessionEvent) -> Void)?) -> (SessionEvent) -> Void {
        { [self] event in
            onEvent?(event)
            emitSessionScopedEvent(event)
        }
    }

    /// Runs one turn's model work and recording, given its already-resolved
    /// prompt text and pending events — the common tail ``generate(grammar:prompt:onEvent:_:)``
    /// (a caller-supplied prompt) and ``dispatchNextPrompt()`` (a queue-sourced
    /// prompt) share once each has resolved its own prompt text and drained
    /// its own pending events, so composing the preamble, timing the turn,
    /// and the finish/requeue/synthetic-close handling live in exactly one
    /// place regardless of where the turn's prompt came from.
    ///
    /// Auto-compaction's proactive half lives here too (task 8213x39): when
    /// ``autoCompactionBudget`` is set, this checks measured context usage
    /// against its ``TokenBudget/triggerTokens`` *before* this turn's own
    /// physical attempt runs —
    /// "turns never die" the same way the proactive pattern documented on
    /// ``compact(prompt:budget:)`` does, just driven by the session itself
    /// instead of by the caller — and folds automatically if it has already
    /// been reached. The reactive half (retry once on context overflow) is
    /// in ``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``.
    ///
    /// That fold can fail — a stop landing in its summarizer call unwinds it (see
    /// ``RoutedSession/cancelCurrentTurn()``) — and it runs *before* the attempt
    /// that owns a turn's recording, so this method records the cut-short turn
    /// itself on that path (``recordFailedTurn(grammar:since:usageBefore:pendingEvents:onEvent:)``).
    /// Without it, a turn abandoned in its own fold would destroy the outbox
    /// events it had already drained and leave no trace of itself at all.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn,
    ///     stamped onto every event this turn appends.
    ///   - turnId: This turn's identity, minted by ``beginTurn()`` and reported
    ///     as ``SessionEvent/turnStarted(_:)`` before any work runs.
    ///   - promptId: The queued prompt this turn dispatched, or `nil` for a turn
    ///     whose prompt came straight from its caller.
    ///   - pendingEvents: The events already drained from the outbox for this
    ///     turn, in outbox order.
    ///   - ownPrompt: This turn's own prompt text, before composing in
    ///     `pendingEvents`.
    ///   - onEvent: This turn's own sink for the ``SessionEvent``s it derives,
    ///     including ``SessionEvent/compaction(_:)`` for any auto-compaction
    ///     fold it triggers, or `nil` when the entry point that started the turn
    ///     has no stream of its own. Either way every event delivered through
    ///     this sink also reaches ``RoutedSession/streamSessionEvents()`` — see
    ///     ``turnEventSink(_:)``, including the text-increment exclusion that
    ///     sink documents.
    ///   - body: The model work to run inside the bracket, given this turn's
    ///     composed prompt and returning the response text callers receive.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event — or `CancellationError` from the
    ///   proactive fold, before `body` is ever called, recorded exactly the same
    ///   way.
    private func runTurn(
        grammar: Grammar?,
        turnId: TurnID,
        promptId: SessionOutbox.ItemID?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        onEvent: ((SessionEvent) -> Void)? = nil,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // The correlation frame, opened before anything this turn does — the
        // proactive fold below included — so every event a consumer sees after
        // it belongs to this turn. See ``SessionEvent/turnStarted(_:)``.
        let emit = turnEventSink(onEvent)

        // Installed for exactly this turn's duration so a live
        // ``ToolInvocationRecord`` posted mid-turn reaches this turn's own
        // stream — see ``deliver(invocation:)`` and
        // ``RoutedSessionActor/currentTurnEventSink``.
        currentTurnEventSink = emit
        defer { currentTurnEventSink = nil }

        emit(.turnStarted(TurnStart(turnId: turnId, promptId: promptId)))

        // Compared in tokens against ``TokenBudget/triggerTokens``, never as
        // `contextFill >= budget.trigger` — see the matching note on the
        // hard-ceiling pre-check in
        // ``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``
        // and ``TokenBudget/triggerTokens`` itself for why those two fractions
        // are not interchangeable.
        if let budget = autoCompactionBudget,
            let measuredTokens = usageState.measuredTokens,
            measuredTokens >= budget.triggerTokens
        {
            let started = Date()
            let usageBefore = backend.usageTokenCounts()
            do {
                let result = try await performAutoCompaction(prompt: autoCompactionPrompt, budget: budget)
                emit(.compaction(result))
            } catch {
                // A fold can now throw — a stop landing inside its summarizer call
                // unwinds it (see ``CancellableCompactionSummarizer``) — and this
                // turn has not reached `runTurnAttempt`, where a failed turn's
                // recording and the outbox's attach-or-requeue rule both live. So
                // the fold's failure path has to run them here, or the events this
                // turn already *destructively* drained would be destroyed and the
                // turn would leave no trace at all. Neither is a formality: an
                // abandoned fold leaves `backend` exactly as it was, so the diff
                // finds no `.prompt` partial to attach those events to and
                // re-queues them, and the synthetic bodyless close is the trace.
                await recordFailedTurn(
                    grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents,
                    onEvent: emit)
                throw error
            }
        }

        await primeDiscoveryIfConfigured(prompt: ownPrompt, emit: emit)

        return try await runTurnAttempt(
            grammar: grammar, pendingEvents: pendingEvents, ownPrompt: ownPrompt, onEvent: emit,
            allowOverflowRetry: autoCompactionBudget != nil, body)
    }

    /// Seeds this turn's pre-discovery pair into ``backend``, when
    /// ``discoveryPriming`` is set — the whole of pre-discovery seeding's
    /// session-side behavior (`^s4405wc`).
    ///
    /// Runs the named mounted tool host-side over `prompt` (a real call through
    /// this session's own instanced tool, so it detaches and caps exactly as the
    /// model's own call would) and reseeds ``backend`` from its current
    /// transcript plus the `.prompt` → `.toolCalls` → `.toolOutput` entries that
    /// call produced, via ``LanguageModelSessionBackend/replacingTranscript(_:)``
    /// — the same reseeding primitive ``compact(prompt:budget:)`` swaps its inner
    /// session through. The turn's own prompt is left untouched: seeding happens
    /// through the transcript, never by rewriting what the caller asked.
    ///
    /// Called from ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``,
    /// deliberately *before* ``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``
    /// rather than inside it, for the two reasons the proactive auto-compaction
    /// fold sits in the same position: a reseeded backend reports its own usage
    /// from zero, so the attempt's `usageBefore` snapshot has to be taken *after*
    /// the swap or the turn's measured delta would go negative; and the reactive
    /// overflow retry recurses into that attempt, where re-priming would run
    /// discovery a second time for one logical turn.
    ///
    /// ``persistedEntryCount`` is deliberately **not** advanced: the seeded
    /// entries are genuinely new, so the turn's own post-generation diff picks
    /// them up and records them like any other entries the SDK appended — which
    /// is what makes them indistinguishable from SDK-native ones on disk.
    ///
    /// Never throws. A failure means the turn generates unseeded, logged here and
    /// surfaced as ``SessionEvent/discoveryPrimingFailed(_:)`` (see
    /// ``DiscoveryPrimingFailure``).
    ///
    /// - Parameters:
    ///   - prompt: This turn's own prompt, passed to the discovery tool as its
    ///     query and recorded as the seeded `.prompt` entry.
    ///   - emit: This turn's composed event sink (``turnEventSink(_:)``), which
    ///     already reaches both this turn's own stream and every session-scoped
    ///     subscription.
    private func primeDiscoveryIfConfigured(
        prompt: String,
        emit: (SessionEvent) -> Void
    ) async {
        guard let discoveryPriming else { return }
        do {
            let seeded = try await DiscoveryPrimer.seededEntries(
                for: prompt, priming: discoveryPriming, mountedTools: tools)
            let transcript = Transcript(entries: backend.transcriptEntries() + seeded)
            backend = backend.replacingTranscript(transcript)
        } catch {
            sessionPrimingLogger.warning(
                "generating unseeded: discovery priming failed for session \(self.id.description, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // One call, two routes: `emit` is this turn's composed sink, which
            // already fans out to this turn's own stream (when the caller
            // started the turn through ``streamEvents(to:maxTokens:)``) *and* to
            // every session-scoped subscription — the route that reaches a
            // subscriber whichever entry point ran the turn, including
            // ``respond(to:maxTokens:)`` and ``dispatchNextPrompt()``, which hand
            // their caller a response rather than a stream (see
            // ``turnEventSink(_:)`` and ``RoutedSession/streamSessionEvents()``).
            emit(.discoveryPrimingFailed(error))
        }
    }

    /// One physical attempt at a turn's model work and recording — the whole
    /// original body of ``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``
    /// before auto-compaction's reactive retry was added, now callable
    /// recursively for that retry (task 8213x39).
    ///
    /// When `allowOverflowRetry` and this attempt throws
    /// `LanguageModelError.contextSizeExceeded` — the SDK's own
    /// context-overflow failure a caller is documented to recover from
    /// reactively on ``compact(prompt:budget:)`` — this attempt is still
    /// recorded exactly like any other failed turn (the synthetic bodyless
    /// close below), so both attempts leave a trace ("recording keeps both
    /// attempts"); this session then folds harder than its own configured
    /// target and retries **once** with a brand-new physical attempt, this
    /// time with `allowOverflowRetry: false` so a second overflow surfaces
    /// rather than looping, and with no `pendingEvents` of its own — the
    /// failed attempt's own finish already re-queued them onto ``outbox``
    /// (see ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:onEvent:)``)
    /// for a future turn to pick up, rather than risking attaching the same
    /// events to two persisted turns. The retry re-runs the model's own work
    /// from scratch — including any tool calls the first attempt made
    /// before overflowing.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn,
    ///     stamped onto every event this turn appends.
    ///   - pendingEvents: The events already drained from the outbox for this
    ///     attempt, in outbox order.
    ///   - ownPrompt: This turn's own prompt text, before composing in
    ///     `pendingEvents`.
    ///   - onEvent: A sink for this turn's derived ``SessionEvent``s, or
    ///     `nil` to skip event derivation entirely.
    ///   - allowOverflowRetry: Whether a context-overflow failure here should
    ///     trigger the one-time compact-and-retry recovery. `false` on the
    ///     retry's own recursive call, so at most one retry ever happens.
    ///   - body: The model work to run inside the bracket, given this turn's
    ///     composed prompt and returning the response text callers receive.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event — unless the failure was a
    ///   recoverable context overflow and a retry was still available, in
    ///   which case the retry's own outcome is returned/thrown instead.
    private func runTurnAttempt(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        onEvent: ((SessionEvent) -> Void)? = nil,
        allowOverflowRetry: Bool,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let composedPrompt = Self.composedPrompt(pendingEvents: pendingEvents, prompt: ownPrompt)

        let started = Date()
        let usageBefore = backend.usageTokenCounts()
        do {
            // The hard-ceiling pre-check (compaction_plan.md §1.7, task g2hcm36):
            // when the budget opts into ``TokenBudget/hardCeiling``, measured
            // usage is checked *before* `body` ever submits this attempt's
            // generate call — deterministic, so a transcript already too
            // large to fit (typically because the proactive fold above
            // couldn't bring it down far enough) fails fast rather than
            // wasting a real generation call on a doomed submission. Thrown
            // from inside this `do` block, exactly like a guided turn's
            // pre-flight grammar-validation failure, so it is recorded as any
            // other failed attempt below (zero-delta usage, since `backend`
            // is never touched) and, via ``isRecoverableContextOverflow(_:)``,
            // recovered by the same fold-harder-and-retry-once path as
            // `LanguageModelError.contextSizeExceeded`.
            //
            // Compared in tokens against ``TokenBudget/ceilingTokens``, never
            // as `contextFill >= hardCeiling`: `contextFill`'s denominator is
            // this session's resolved ``contextTokens`` while the ceiling is a
            // fraction of the budget's own ``TokenBudget/limit``, so the two
            // fractions are only comparable when those happen to be the same
            // number (see ``TokenBudget/triggerTokens``). An unmeasured session
            // (``ContextUsageState/measuredTokens`` `nil`) is left alone rather
            // than blocked on a guess.
            if let budget = autoCompactionBudget,
                let hardCeiling = budget.hardCeiling,
                let ceilingTokens = budget.ceilingTokens,
                let measuredTokens = usageState.measuredTokens,
                measuredTokens >= ceilingTokens
            {
                throw ContextBudgetError.hardCeilingExceeded(
                    fill: budget.fill(measuredTokens: measuredTokens), ceiling: hardCeiling)
            }
            let response = try await runCancellableModelCall(composedPrompt: composedPrompt, body)
            // A turn can succeed (return a response) yet still leave the SDK's
            // transcript unchanged for some future conformer — attach-or-requeue
            // applies uniformly on both exits (see the catch branch's matching
            // comment), not just the throwing one; that uniform check lives in
            // ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:onEvent:)``.
            _ = await finishTurnAndRequeueIfUnattached(
                grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents,
                onEvent: onEvent)
            return response
        } catch {
            await recordFailedTurn(
                grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents,
                onEvent: onEvent)

            guard allowOverflowRetry, let budget = autoCompactionBudget, Self.isRecoverableContextOverflow(error) else {
                throw error
            }

            let loweredBudget = TokenBudget(
                limit: budget.limit, trigger: budget.trigger, target: Self.loweredRetryTarget(from: budget.target))
            let result = try await performAutoCompaction(prompt: autoCompactionPrompt, budget: loweredBudget)
            onEvent?(.compaction(result))

            return try await runTurnAttempt(
                grammar: grammar, pendingEvents: [], ownPrompt: ownPrompt, onEvent: onEvent,
                allowOverflowRetry: false, body)
        }
    }

    /// Records a turn that ended in a failure: the post-failure transcript diff,
    /// the outbox's attach-or-requeue rule, and the synthetic bodyless close.
    ///
    /// Whatever the SDK durably appended before failing is still diffed and
    /// persisted, with `ms` stamped the same way as the success path (on the
    /// diff's own last `.response`-kind entry, if any) — a post-generation
    /// failure can still leave the SDK having appended a genuine `.response`
    /// entry before throwing. The router-only bodyless close is synthesized only
    /// when that diff did *not* already include a `.response`-kind entry, since
    /// otherwise one turn would close twice, breaking the "exactly one close per
    /// turn" invariant. Either way every failed turn leaves a trace: the SDK's
    /// own `.response` entry, or this synthetic one.
    ///
    /// Shared by the two places a turn can fail, so neither can drift into
    /// recording a different shape than the other: a physical attempt that threw
    /// (``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``'s
    /// catch) and a turn cut short inside the proactive fold it runs *before* its
    /// first attempt (``runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``).
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn.
    ///   - started: The turn's start time, stamped as `ms`.
    ///   - usageBefore: The token-usage snapshot taken before the failed work ran.
    ///   - pendingEvents: The events this turn drained from ``outbox``, re-queued
    ///     unless the diff produced a `.prompt`-kind partial to attach them to.
    ///   - onEvent: A sink for this turn's derived ``SessionEvent``s, or `nil`.
    private func recordFailedTurn(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async {
        let (diffIncludedResponse, usage) = await finishTurnAndRequeueIfUnattached(
            grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents,
            onEvent: onEvent)
        guard !diffIncludedResponse else { return }
        await append(
            partial: makePartialEvent(
                kind: .response,
                grammar: grammar,
                since: started,
                tokensIn: usage?.input,
                tokensOut: usage?.output
            )
        )
    }

    /// The `tool` identity stamped on the turn-scope ambient ``ToolContext``
    /// binding — a host-level stamp, since the binding covers a whole model
    /// call rather than one wrapped tool (per-tool stamps live in the
    /// per-call bindings of ``RunToCompletionTool``, ``BackgroundTool``, and
    /// ``ContextBindingTool``).
    private static let turnBindingToolStamp = "session"

    /// The `op` stamped on the turn-scope ambient binding, alongside
    /// ``turnBindingToolStamp``.
    private static let turnBindingOpStamp = "respond"

    /// Mirrors one model-call task's cancellation into a synchronous probe
    /// the turn's ambient ``ToolContext`` binding reports verbatim —
    /// ``ToolContext/isCancelled`` must report the probe the invoker bound,
    /// never `Task.isCancelled` of whichever task happens to read it. The
    /// holder exists because the context must be constructed before the
    /// model-call task it probes: ``bind(to:)`` closes the loop right after
    /// the task is created, and the unbound window reads `false` — correct,
    /// since ``RoutedSession/cancelCurrentTurn()`` can only cancel a model
    /// call that exists.
    private final class ModelCallCancellationProbe: Sendable {
        /// The model-call task being probed, bound once it exists.
        private let modelCall = Mutex<Task<String, any Error>?>(nil)

        /// Binds the created model-call task as the probe's subject.
        ///
        /// - Parameter task: The model-call task whose cancellation this probe
        ///   reports.
        func bind(to task: Task<String, any Error>) {
            modelCall.withLock { $0 = task }
        }

        /// Whether the bound model call has been cancelled.
        var isCancelled: Bool {
            modelCall.withLock { $0?.isCancelled ?? false }
        }
    }

    /// Runs one attempt's model call in a task this session can cancel from
    /// outside the turn, and awaits its result.
    ///
    /// The whole cancellation boundary in-flight cancellation needs — and
    /// deliberately the *only* part of a turn inside it. Cancelling
    /// ``inFlightModelCall`` unwinds `body` and every un-detached tool call
    /// the SDK is running under it — including a non-String-output tool's
    /// call through its binding-only ``ContextBindingTool`` wrapper (task
    /// ^6htgvw2), which runs in-band and dies with the turn: its per-call
    /// `completionToken` is event-correlation identity only, never a
    /// mailbox-addressable run. A String-output tool from the session's
    /// composed list is wrapped in ``RunToCompletionTool`` or
    /// ``BackgroundTool`` (task ^k4nygqa). One
    /// that runs to completion dies with the turn like any other in-band
    /// call. One that declared ``DetachConfiguration/Mode/background`` for
    /// itself handed back its pending envelope the moment it was called, so
    /// the cancellation never reaches its run: it keeps running in the
    /// session's ``mailbox``. The background run stays individually
    /// addressable — ``SessionMailbox/cancel(completionToken:)`` — and
    /// ``close()``'s sweep settles whatever remains; its `.completed`
    /// rides a later turn through the outbox as usual. The turn's
    /// recording runs after this returns or throws and is never cancelled
    /// with it (see ``RoutedSession/cancelCurrentTurn()``).
    ///
    /// Internal rather than `private` for one caller:
    /// ``CancellableCompactionSummarizer``, which routes a fold's own summarizer
    /// call through here so that model call is cancellable on exactly the same
    /// terms as a turn's.
    ///
    /// The unstructured task is bracketed by `withTaskCancellationHandler` so
    /// cancelling the *caller's* own enclosing `Task` still reaches the model
    /// call: an unstructured task is not a child, so nothing would propagate into
    /// it otherwise — and that propagation is a contract Router had before it had
    /// a cancellation primitive of its own (plan.md, "Turn loop").
    ///
    /// - Parameters:
    ///   - composedPrompt: This attempt's composed prompt, handed to `body`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws — `CancellationError` when the model work
    ///   observed a cancellation — or `CancellationError` directly when this turn
    ///   had already been cancelled, by either route, before its model call
    ///   started.
    internal func runCancellableModelCall(
        composedPrompt: String,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // A cancellation that landed while this turn held no model call — inside a
        // fold's deterministic stages, between two of its summarizer calls, or
        // between a failed attempt and this retry — had no task to cancel, so it is
        // honored here instead of being dropped, and the model (with every tool call
        // it would make) is never re-entered on behalf of a turn already cancelled.
        if isTurnCancelled {
            throw CancellationError()
        }
        // The host-side ambient binding (task ^k4nygqa): every backend respond()/stream
        // call runs under a ``ToolContext`` carrying this session's
        // identity, its mailbox, and its own ``SessionOutbox`` as the
        // upstream sink — so a tool Apple's runtime invokes from inside the
        // model call sees the same ambient capabilities the detachment
        // engine binds per call. Whether the runtime actually propagates
        // task locals into `Tool.call` is the propagation probe's question;
        // this binding is correct either way, and ``RunToCompletionTool`` and
        // ``BackgroundTool`` also bind per call regardless. The
        // `completionToken` is minted fresh
        // per model call — run scope, never session scope — and the
        // cancellation probe mirrors this very model-call task's
        // cancellation (bound just after creation, because the context must
        // exist before the task it probes).
        let cancellationProbe = ModelCallCancellationProbe()
        let turnContext = ToolContext(
            sessionID: id,
            mailbox: mailbox,
            sink: outbox,
            tool: Self.turnBindingToolStamp,
            op: Self.turnBindingOpStamp,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { cancellationProbe.isCancelled }
        )
        // The permit this turn is running on, published for exactly this model
        // call (task ^1zt7vyg). A tool the model invokes from inside the call
        // reads it, and a turn that tool starts on *another* session over the
        // same resident container runs on this permit instead of waiting for
        // one that only comes back when this turn ends. Closed in the `defer`
        // below, so a run that detached and outlived the call cannot borrow on
        // it. See ``GenerationPermitLoan``.
        let permitLoan = GenerationPermitLoan(
            gate: generationGate,
            sessionID: id,
            holdsPermit: holdsGenerationPermit || borrowsGenerationPermit
        )
        currentPermitLoan = permitLoan
        // Identity-matched for the same reason the model call below is: a later
        // attempt's own loan is never cleared by an earlier one's unwind.
        defer {
            if currentPermitLoan === permitLoan {
                currentPermitLoan = nil
            }
            permitLoan.close()
        }
        // The stall watch (task ^z6xcmnh), opened before the call and closed
        // by its own `defer`. It bounds nothing: the watchdog only reports a
        // ``GenerationStall`` on each interval the call goes without observable
        // progress, so a decode that stops making progress becomes visible
        // while it is still running instead of only when it finally ends. See
        // ``RoutedSessionActor/reportGenerationStall(id:)``.
        let stallWatchId = beginGenerationStallWatch()
        let stallWatchdog = Task { await self.watchGenerationForStalls(id: stallWatchId) }
        defer {
            stallWatchdog.cancel()
            endGenerationStallWatch(id: stallWatchId)
        }
        let modelCall = Task {
            try await GenerationPermitLoan.$current.withValue(permitLoan) {
                try await ToolContext.$current.withValue(turnContext) {
                    try await body(composedPrompt)
                }
            }
        }
        cancellationProbe.bind(to: modelCall)
        inFlightModelCall = modelCall
        // Identity-matched rather than unconditional, so a later attempt's own
        // model call is never cleared by an earlier one's unwind.
        defer {
            if inFlightModelCall == modelCall {
                inFlightModelCall = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await modelCall.value
        } onCancel: {
            modelCall.cancel()
        }
    }

    /// Whether a cancellation is outstanding against the turn in flight, by either
    /// route — the single predicate every "is this turn still wanted?" decision
    /// asks, so the two routes can never diverge between them.
    ///
    /// `Task.isCancelled` is this turn's own caller having cancelled its enclosing
    /// task; ``cancelRequestedTurnId`` is ``RoutedSession/cancelCurrentTurn()``
    /// having recorded a request against the turn now holding ``turnLock``. Both are
    /// asked, so neither route can do what the other cannot.
    ///
    /// Read *after* every `await` that matters, never cached across one: what makes
    /// this correct is that it is cheap to re-ask.
    var isTurnCancelled: Bool {
        if Task.isCancelled { return true }
        guard let turnId = currentTurnId else { return false }
        return cancelRequestedTurnId == turnId
    }

    /// Whether `error` is a recoverable context-overflow failure —
    /// the SDK's own `LanguageModelError.contextSizeExceeded` (macOS 27), hit
    /// mid-generation, or this package's own deterministic
    /// ``ContextBudgetError/hardCeilingExceeded(fill:ceiling:)``, hit
    /// pre-flight by the hard-ceiling check in
    /// ``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``
    /// — the two errors ``runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``
    /// recovers from reactively when auto-compaction is opted in, mirroring
    /// the documented reactive recovery pattern on
    /// ``compact(prompt:budget:)``.
    ///
    /// - Parameter error: The error a turn attempt threw.
    /// - Returns: `true` for either recoverable context-overflow failure,
    ///   `false` for any other error.
    private static func isRecoverableContextOverflow(_ error: Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error {
            return true
        }
        if case ContextBudgetError.hardCeilingExceeded = error {
            return true
        }
        return false
    }

    /// The divisor ``loweredRetryTarget(from:)`` applies to a budget's own
    /// configured target — halving, the smallest reduction that lands strictly
    /// below every positive target without ever reaching zero.
    private static let retryTargetHalvingDivisor: Double = 2

    /// The fold target the reactive overflow-recovery retry compacts to:
    /// strictly lower than the budget's own configured target, mirroring the
    /// documented reactive pattern's own hardcoded "fold harder" example
    /// (``compact(prompt:budget:)``'s own doc comment folds to `0.35`
    /// against a default `0.50` target) — computed relative to whatever
    /// `target` the caller actually configured, so halving is all it takes to
    /// stay strictly lower without ever reaching zero for a positive target.
    ///
    /// Deliberately carries no absolute floor. An earlier `max(target / 2, 0.1)`
    /// broke this method's own "strictly lower" contract for every target under
    /// `0.2`, and inverted it outright under `0.1`: a budget configured to fold
    /// to 5% of its limit had its *recovery* retry fold to 10%, i.e. softer than
    /// the target that had already overflowed, so the retry was a guaranteed
    /// no-op and the overflow surfaced to the caller. A floor stated as a
    /// fraction cannot be right here anyway — what counts as "meaningfully
    /// hard" depends on ``TokenBudget/limit``, which this fraction knows
    /// nothing about.
    ///
    /// - Parameter target: The budget's own configured target.
    /// - Returns: The lowered target the retry's fold uses.
    private static func loweredRetryTarget(from target: Double) -> Double {
        target / retryTargetHalvingDivisor
    }

    /// Runs the earliest still-pending queued prompt as one normal recorded
    /// turn — the driver's pull surface over ``outbox``'s prompt queue. See
    /// ``RoutedSession/dispatchNextPrompt()`` for the full contract and the
    /// intended driver-loop shape.
    ///
    /// Dequeues the front queued prompt together with any pending
    /// turn-riding events in one atomic ``SessionOutbox/drainForDispatch()``
    /// call, inside the same two gates ``generate(grammar:prompt:onEvent:_:)`` runs
    /// its own bracket in — so a dispatch never interleaves with a concurrent
    /// ``respond(to:maxTokens:)``/``streamResponse(to:maxTokens:)`` turn, and
    /// races ``cancel(id:)``/``replace(id:prompt:)`` exactly at the drain: once
    /// this call has drained an id, a `cancel`/`replace` racing it on that id
    /// finds it already gone from the queue and reports
    /// ``SessionOutbox/PromptQueueMutationResult/alreadySent``, leaving this
    /// in-flight turn unaffected.
    ///
    /// Honors ``grammar`` exactly like ``respond(to:maxTokens:)``: a guided
    /// session constrains this turn's response too.
    ///
    /// The dispatched prompt's id is reported as this turn's
    /// ``SessionEvent/turnStarted(_:)`` frame, so a client that enqueued it can
    /// tie it to the turn it caused and to every event that turn produces; the
    /// same id stays visible in ``SessionOutbox/queueDepth()`` for as long as
    /// the turn runs, which is what makes a drained-but-unfinished prompt
    /// observable instead of falling between the queue and the transcript.
    ///
    /// **The delivery rule (task ^ftdmr58).** A drain that finds no queued
    /// prompt but holds a settled run's terminal runs a *delivery turn*: the
    /// terminal rides that turn's preamble ahead of
    /// ``settledRunDeliveryPrompt``, so a driver woken by a settlement hears
    /// it without any `wait` call from the model. A drain that holds only
    /// progress or elicitation reports re-queues them and runs no turn.
    ///
    /// - Returns: The response text the dispatched or delivery turn produced,
    ///   or `nil` when nothing was queued and no run had settled — including
    ///   the case where a concurrent ``cancel(id:)`` won the race for the only
    ///   queued prompt.
    /// - Throws: Whatever the dispatched turn throws, recorded exactly as any
    ///   other failed turn is.
    func dispatchNextPrompt() async throws -> String? {
        let turnId = try await beginTurn()
        defer { endTurn() }

        let drained = await outbox.drainForDispatch()
        let pendingEvents = drained.events.map(\.event)
        guard let queued = drained.prompt else {
            return try await deliverSettledRunsIfAny(turnId: turnId, pendingEvents: pendingEvents)
        }

        // Only now — with a prompt confirmed to actually dispatch as a turn
        // — is it safe to record the session's first-line meta event.
        await recordSessionMetaIfNeeded()
        return try await runDispatchedTurn(
            turnId: turnId, promptId: queued.id, pendingEvents: pendingEvents,
            ownPrompt: TranscriptEntryMapper.flattenedText(queued.prompt))
    }

    /// The empty-queue half of ``dispatchNextPrompt()``: runs a delivery turn
    /// when `pendingEvents` holds a run's terminal, and re-queues them
    /// otherwise.
    ///
    /// Nothing was queued to dispatch — including the case where a concurrent
    /// `cancel(id:)` won the race for the only queued prompt just before the
    /// drain. Events the drain claimed and no turn carries were never
    /// delivered, so they are re-queued rather than destroyed (the same
    /// "claimed but never delivered" rule the respond/streamResponse path
    /// applies). That path deliberately does NOT record the session meta
    /// line: a session that never runs a turn writes no file at all.
    ///
    /// - Parameters:
    ///   - turnId: This turn's identity, minted by ``beginTurn()``.
    ///   - pendingEvents: The events the drain claimed, in outbox order.
    /// - Returns: The delivery turn's response, or `nil` when no turn ran.
    /// - Throws: Whatever the delivery turn throws.
    private func deliverSettledRunsIfAny(turnId: TurnID, pendingEvents: [OperationEvent]) async throws -> String? {
        guard pendingEvents.contains(where: { $0.kind == .completed }) else {
            await requeueUnattachedPendingEvents(events: pendingEvents)
            await outbox.finishDispatch()
            return nil
        }
        await recordSessionMetaIfNeeded()
        return try await runDispatchedTurn(
            turnId: turnId, promptId: nil, pendingEvents: pendingEvents,
            ownPrompt: Self.settledRunDeliveryPrompt)
    }

    /// Runs one turn under the dispatch bracket and releases the outbox's
    /// dispatched slot on every exit.
    ///
    /// The turn's outcome is captured rather than returned directly so the
    /// slot is released on every exit — a `defer` cannot, because releasing
    /// it is an `await` on another actor. That release suspends after the
    /// outcome is decided and before `endTurn()` clears `currentTurnId`, so a
    /// ``RoutedSession/cancelPrompt(id:)`` scheduled into that suspension
    /// still finds the id in the slot and a turn in flight (the
    /// completed-turn window documented there). The slot is emptied while
    /// this turn holds the lock, so it never names a finished prompt while a
    /// later turn runs.
    ///
    /// - Parameters:
    ///   - turnId: This turn's identity, minted by ``beginTurn()``.
    ///   - promptId: The queued prompt this turn dispatched, or `nil` for a
    ///     delivery turn.
    ///   - pendingEvents: The events the drain claimed, in outbox order.
    ///   - ownPrompt: This turn's own prompt text.
    /// - Returns: The response text the turn produced.
    /// - Throws: Whatever the turn throws.
    private func runDispatchedTurn(
        turnId: TurnID, promptId: SessionOutbox.ItemID?, pendingEvents: [OperationEvent], ownPrompt: String
    ) async throws -> String {
        let outcome: Result<String, any Error>
        do {
            outcome = .success(
                try await runTurn(
                    grammar: grammar, turnId: turnId, promptId: promptId, pendingEvents: pendingEvents,
                    ownPrompt: ownPrompt, respondBody(grammar: grammar, maxTokens: nil)
                ))
        } catch {
            outcome = .failure(error)
        }
        await outbox.finishDispatch()
        return try outcome.get()
    }

    /// Composes this turn's actual model-visible prompt: `pendingEvents`
    /// rendered as a plain-text preamble (one line per event, in outbox order
    /// — see ``OperationEventSegment/renderedLine(for:)``), a blank line, then
    /// the caller's own `prompt` — or `prompt` unchanged when `pendingEvents`
    /// is empty, so an empty outbox produces byte-identical behavior to a
    /// session that never used one.
    ///
    /// - Parameters:
    ///   - pendingEvents: The events drained from the outbox for this turn, in
    ///     outbox order.
    ///   - prompt: The caller's own prompt.
    /// - Returns: The composed, model-visible prompt string.
    private static func composedPrompt(pendingEvents: [OperationEvent], prompt: String) -> String {
        guard !pendingEvents.isEmpty else { return prompt }
        let preamble = pendingEvents.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n")
        return preamble + "\n\n" + prompt
    }
}
