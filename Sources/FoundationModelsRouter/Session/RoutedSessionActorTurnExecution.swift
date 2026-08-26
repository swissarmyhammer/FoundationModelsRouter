import Foundation
import FoundationModels
import Synchronization
import os

/// The logger for a turn's failed pre-discovery seeding.
private let sessionPrimingLogger = makeModuleLogger(category: "DiscoveryPriming")

/// ``RoutedSessionActor``'s turn execution: the recorder-bracketed generation
/// chokepoint, the queued-prompt turn, discovery priming, overflow recovery, and cancellation.
extension RoutedSessionActor {
    /// Builds the closure that submits a turn's composed prompt to `backend`.
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

    /// The single recorder-bracketed generation chokepoint every public method runs through.
    ///
    /// The bracket holds ``turnLock`` and a ``RoutedModel/generationGate`` permit. It drains
    /// pending events from ``outbox`` into the prompt, runs `body`, then records the transcript delta.
    ///
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after the turn is recorded.
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

    /// Composes a turn's own event sink with the session-scoped fan-out.
    ///
    /// - Parameter onEvent: This turn's own sink, or `nil`.
    private func turnEventSink(_ onEvent: ((SessionEvent) -> Void)?) -> (SessionEvent) -> Void {
        { [self] event in
            onEvent?(event)
            emitSessionScopedEvent(event)
        }
    }

    /// Runs one turn's model work and recording. The caller must hold both turn gates.
    ///
    /// When ``autoCompactionBudget`` is set and measured usage has reached
    /// ``TokenBudget/triggerTokens``, the turn folds first. A fold that throws
    /// is recorded as a failed turn.
    ///
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the fold.
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

    /// Seeds this turn's pre-discovery entries into ``backend`` when ``discoveryPriming`` is set.
    ///
    /// Must run before the attempt takes its `usageBefore` snapshot. Never throws: a
    /// failure is logged and reported as ``SessionEvent/discoveryPrimingFailed(_:)``.
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

    /// One physical attempt at a turn's model work and recording.
    ///
    /// A recoverable context overflow is recorded as a failed attempt. When
    /// `allowOverflowRetry` is set, the session folds to a lower target and retries once.
    ///
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or the retry's own outcome when a retry ran.
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

    /// Records a turn that ended in a failure: the transcript diff, the
    /// attach-or-requeue of pending events, and a bodyless `.response` close
    /// when the diff did not already include one.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn.
    ///   - started: The turn's start time.
    ///   - usageBefore: The token-usage snapshot taken before the failed work ran.
    ///   - pendingEvents: The events this turn drained from ``outbox``.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
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

    /// The `tool` identity stamped on the turn-scope ambient ``ToolContext`` binding.
    private static let turnBindingToolStamp = "session"

    /// The `op` stamped on the turn-scope ambient binding.
    private static let turnBindingOpStamp = "respond"

    /// Mirrors one model-call task's cancellation into a synchronous probe that
    /// the turn's ambient ``ToolContext`` binding reports. The unbound window reads `false`.
    private final class ModelCallCancellationProbe: Sendable {
        /// The model-call task being probed, bound once it exists.
        private let modelCall = Mutex<Task<String, any Error>?>(nil)

        /// Binds the created model-call task as the probe's subject.
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
    /// Cancelling ``inFlightModelCall`` unwinds `body` and every in-band tool call
    /// under it. A background run keeps running in the session's ``mailbox``. The
    /// turn's recording runs after this returns or throws and is never cancelled.
    /// ``CancellableCompactionSummarizer`` also routes a fold's summarizer call through here.
    ///
    /// - Parameters:
    ///   - composedPrompt: This attempt's composed prompt, handed to `body`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` when this turn
    ///   was already cancelled before its model call started.
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
        // model call sees the same ambient capabilities the mounting
        // engine binds per call. Whether the runtime actually propagates
        // task locals into `Tool.call` is the propagation probe's question;
        // this binding is correct either way, and ``RunToCompletionRunner`` and
        // ``BackgroundToolRunner`` also bind per call regardless. The
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
        // below, so a run that went to the background and outlived the call cannot borrow on
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
    /// route: the caller's own `Task.isCancelled`, or ``cancelRequestedTurnId``
    /// set by ``RoutedSession/cancelCurrentTurn()``. Read after each `await`; do not cache.
    var isTurnCancelled: Bool {
        if Task.isCancelled { return true }
        guard let turnId = currentTurnId else { return false }
        return cancelRequestedTurnId == turnId
    }

    /// Whether `error` is a recoverable context-overflow failure:
    /// `LanguageModelError.contextSizeExceeded` or
    /// ``ContextBudgetError/hardCeilingExceeded(fill:ceiling:)``.
    private static func isRecoverableContextOverflow(_ error: Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error {
            return true
        }
        if case ContextBudgetError.hardCeilingExceeded = error {
            return true
        }
        return false
    }

    /// The divisor ``loweredRetryTarget(from:)`` applies to a budget's configured target.
    private static let retryTargetHalvingDivisor: Double = 2

    /// The fold target the overflow-recovery retry compacts to: strictly lower
    /// than the budget's configured target, with no absolute floor.
    ///
    /// - Parameter target: The budget's own configured target.
    /// - Returns: The lowered target the retry's fold uses.
    private static func loweredRetryTarget(from target: Double) -> Double {
        target / retryTargetHalvingDivisor
    }

    /// Runs the earliest still-pending queued prompt as one normal recorded turn.
    /// See ``RoutedSession/dispatchNextPrompt()`` for the full contract.
    ///
    /// Dequeues the front prompt and any pending events in one atomic
    /// ``SessionOutbox/drainForDispatch()`` call, inside the same two gates
    /// ``generate(grammar:prompt:onEvent:_:)`` uses. Honors ``grammar``. The
    /// prompt's id is reported in ``SessionEvent/turnStarted(_:)``.
    ///
    /// A drain that finds no queued prompt but holds a settled run's terminal runs
    /// a delivery turn with ``settledRunDeliveryPrompt``. A drain that holds only
    /// progress or elicitation reports re-queues them and runs no turn.
    ///
    /// - Returns: The response text the turn produced, or `nil` when no turn ran.
    /// - Throws: Whatever the dispatched turn throws.
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
    /// when `pendingEvents` holds a run's terminal, and re-queues them otherwise.
    /// The re-queue path does not record the session meta line.
    ///
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
    /// dispatched slot on every exit. The release is an `await`, so the outcome
    /// is captured instead of returned directly.
    ///
    /// - Parameters:
    ///   - turnId: This turn's identity, minted by ``beginTurn()``.
    ///   - promptId: The queued prompt this turn dispatched, or `nil` for a delivery turn.
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

    /// Composes this turn's model-visible prompt: `pendingEvents` rendered as a
    /// plain-text preamble (see ``OperationEventSegment/renderedLine(for:)``), a blank
    /// line, then `prompt`. Returns `prompt` unchanged when `pendingEvents` is empty.
    private static func composedPrompt(pendingEvents: [OperationEvent], prompt: String) -> String {
        guard !pendingEvents.isEmpty else { return prompt }
        let preamble = pendingEvents.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n")
        return preamble + "\n\n" + prompt
    }
}
