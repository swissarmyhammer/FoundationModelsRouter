import Foundation
import FoundationModels
import Synchronization
import Tracing
import os

/// The logger for a turn's failed pre-discovery seeding.
private let sessionPrimingLogger = makeModuleLogger(category: "DiscoveryPriming")

/// ``RoutedSessionActor``'s turn execution: the recorder-bracketed generation
/// chokepoint, the queued-prompt turn, discovery priming, the recovery from an
/// overflow or a rejected tool call, and cancellation.
extension RoutedSessionActor {
    /// The token ceiling a turn gives its backend.
    ///
    /// A ceiling the caller names wins. Otherwise the ceiling is the resolved
    /// working context of the session: a response cannot be longer than the
    /// context it decodes in, so the context is the one ceiling that comes from
    /// the model. The length of a turn below that is for the bounds made to
    /// govern it, such as the stall report and a host watchdog, and not for a
    /// constant.
    ///
    /// - Parameters:
    ///   - requested: The ceiling the caller named, or `nil`.
    ///   - contextTokens: The resolved working context of the session, in tokens.
    /// - Returns: The ceiling to give the backend, or `nil` when the caller
    ///   named none and the context is unknown. The backend then sends the
    ///   window of its model to the engine.
    static func responseTokenCeiling(requested: Int?, contextTokens: Int) -> Int? {
        if let requested { return requested }
        guard contextTokens > 0 else { return nil }
        return contextTokens
    }

    /// Builds the closure that submits a turn's composed prompt to `backend`.
    ///
    /// - Parameters:
    ///   - grammar: The grammar that constrains the response, or `nil`.
    ///   - maxTokens: The ceiling to give the backend, as
    ///     ``responseTokenCeiling(requested:contextTokens:)`` derives it.
    /// - Returns: The closure that runs the model call.
    func respondBody(grammar: Grammar?, responseTokenCeiling maxTokens: Int?) -> @Sendable (String) async throws -> String {
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
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn, or `nil`.
    ///   - entryPoint: The surface this turn was started through, which the
    ///     turn's span reports. Every caller states it, because the chokepoint
    ///     cannot tell one surface from another.
    ///   - prompt: This turn's own prompt text.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and
    ///     the ceiling the caller named. The recording reads the resolved
    ///     ceiling to find ``TokenUsage/finishReason``. The retry after a
    ///     context overflow reads the ceiling the caller named.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after the turn is recorded.
    func generate(
        grammar: Grammar? = nil,
        entryPoint: RouterTracing.TurnEntryPoint,
        prompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
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
        // compacted into *this* turn's prompt, here inside the turn lock so a
        // drain never interleaves with a concurrent turn. This caller supplies
        // its own prompt directly, so only events are drained — never the
        // queued-prompt FIFO (see `SessionOutbox.drainPendingEvents()`, as
        // opposed to `SessionOutbox.drainForDispatch()`, which only
        // ``dispatchNextPrompt()`` uses): a prompt waiting in the queue is left
        // exactly where it is rather than silently dequeued and discarded by
        // an unrelated ad hoc turn. An empty outbox drains to an empty
        // `pendingEvents`, so ``composedPrompt(pendingEvents:prompt:)`` returns
        // `prompt` unchanged and ``attachingPendingEventSegments(events:to:)``
        // attaches nothing below — byte-identical to a session that never
        // used an outbox.
        let pendingEvents = await outbox.drainPendingEvents().map(\.event)
        await notifyTurnBoundaryTools()
        return try await runTurn(
            grammar: grammar, turnId: turnId, entryPoint: entryPoint, promptId: nil,
            pendingEvents: pendingEvents, ownPrompt: prompt, responseTokenCeiling: responseTokenCeiling,
            onEvent: onEvent, body)
    }

    /// Calls ``TurnBoundaryTool/turnWillBegin()`` once on every mounted tool
    /// that conforms, in mount order — the clock tick a tool uses to apply a
    /// change it prepared at the side (task w77k41m).
    ///
    /// Runs at both drain sites (this turn's own ``outbox`` drain in
    /// ``generate(grammar:entryPoint:prompt:responseTokenCeiling:onEvent:_:)`` and ``dispatchNextPrompt()``'s),
    /// after the drain and before the model call of the turn — so a turn that
    /// fails before the model call still made the hook call, and a fork's
    /// hook fires only on the fork's own tools (``ForkableTool`` composition).
    private func notifyTurnBoundaryTools() async {
        for tool in tools {
            guard let boundaryTool = tool as? any TurnBoundaryTool else { continue }
            await boundaryTool.turnWillBegin()
        }
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

    /// Runs one turn inside that turn's own span. The caller must hold both turn gates.
    ///
    /// Every generation surface reaches this one method, so the span it opens
    /// covers all of them: ``RoutedSession/respond(to:maxTokens:)``,
    /// ``RoutedSession/streamResponse(to:maxTokens:)``,
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` and
    /// ``RoutedSession/dispatchNextPrompt()``. Those methods state the span
    /// contract; ``RouterTracing`` states the rule that keeps content off it.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn.
    ///   - turnId: This turn's identity, minted by ``beginTurn()``.
    ///   - entryPoint: The surface this turn was started through.
    ///   - promptId: The queued prompt this turn dispatched, or `nil`.
    ///   - pendingEvents: The events this turn drained from ``outbox``.
    ///   - ownPrompt: This turn's own prompt text.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the compaction.
    ///   `withSpan` records the error on the span and raises it again.
    private func runTurn(
        grammar: Grammar?,
        turnId: TurnID,
        entryPoint: RouterTracing.TurnEntryPoint,
        promptId: PromptID?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.turn, ofKind: .client) { span in
                span.attributes[RouterTracing.AttributeKey.routerId] = routerId.description
                span.attributes[RouterTracing.AttributeKey.sessionId] = id.description
                span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
                span.attributes[RouterTracing.AttributeKey.turnId] = turnId.description
                span.attributes[RouterTracing.AttributeKey.turnEntryPoint] = entryPoint.rawValue
                let response = try await runTurnWork(
                    grammar: grammar, turnId: turnId, promptId: promptId,
                    pendingEvents: pendingEvents, ownPrompt: ownPrompt,
                    responseTokenCeiling: responseTokenCeiling, onEvent: onEvent, body)
                recordMeasuredTokens(on: span)
                return response
            }
    }

    /// Writes this turn's measured token counts onto `span`.
    ///
    /// A turn whose diff carried a `.response` entry leaves ``usageState``
    /// measured: the fed and generated tokens of the newest generation call.
    /// Those two numbers are what the span reports. A turn the
    /// backend could not meter leaves the state unmeasured, and the span then
    /// carries no token attribute at all rather than a guess.
    ///
    /// - Parameter span: This turn's span.
    private func recordMeasuredTokens(on span: any Span) {
        guard case .measured(let input, let output) = usageState else { return }
        span.attributes[RouterTracing.AttributeKey.tokensIn] = input
        span.attributes[RouterTracing.AttributeKey.tokensOut] = output
    }

    /// Runs one turn's model work and recording. The caller must hold both turn gates.
    ///
    /// When ``autoCompactionBudget`` is set and measured usage has reached
    /// ``TokenBudget/triggerTokens``, the turn compacts first. A compaction that throws
    /// is recorded as a failed turn.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn.
    ///   - turnId: This turn's identity, minted by ``beginTurn()``.
    ///   - promptId: The queued prompt this turn dispatched, or `nil`.
    ///   - pendingEvents: The events this turn drained from ``outbox``.
    ///   - ownPrompt: This turn's own prompt text.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the compaction.
    private func runTurnWork(
        grammar: Grammar?,
        turnId: TurnID,
        promptId: PromptID?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // The correlation frame, opened before anything this turn does — the
        // proactive compaction below included — so every event a consumer sees after
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
        // ``runTurnAttempt(grammar:pendingEvents:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:_:)``
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
                // A compaction can now throw — a stop landing inside its summarizer call
                // unwinds it (see ``CancellableCompactionSummarizer``) — and this
                // turn has not reached `runTurnAttempt`, where a failed turn's
                // recording and the outbox's attach-or-requeue rule both live. So
                // the compaction's failure path has to run them here, or the events this
                // turn already *destructively* drained would be destroyed and the
                // turn would leave no trace at all. Neither is a formality: an
                // abandoned compaction leaves `backend` exactly as it was, so the diff
                // finds no `.prompt` partial to attach those events to and
                // re-queues them, and the synthetic close is the trace.
                await recordFailedTurn(
                    grammar: grammar, since: started, usageBefore: usageBefore,
                    responseTokenCeiling: responseTokenCeiling.resolved, pendingEvents: pendingEvents, onEvent: emit)
                throw error
            }
        }

        await primeDiscoveryIfConfigured(prompt: ownPrompt, emit: emit)

        return try await runTurnAttempt(
            grammar: grammar, pendingEvents: pendingEvents, ownPrompt: ownPrompt,
            responseTokenCeiling: responseTokenCeiling, onEvent: emit,
            allowOverflowRetry: autoCompactionBudget != nil, body
        )
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
    /// A failed attempt is recorded, and then
    /// ``recoverFailedAttempt(from:grammar:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:_:)``
    /// runs the attempt again when a recovery applies: a rejected tool call
    /// goes back to the model, and a recoverable context overflow compacts to the
    /// target ``OverflowRetryTarget`` chooses and retries once when
    /// `allowOverflowRetry` is set.
    ///
    /// A model call that a tool result stopped for a compaction
    /// (``noteToolResult(_:)``) is not a failure. The attempt goes on in
    /// ``continueAfterCompactionYield(_:attempt:body:)``. An attempt that
    /// stopped at its output token ceiling over the trigger
    /// (``compactsAfterCeilingStop(_:)``) goes on in
    /// ``continueAfterCeilingStop(attempt:body:)``. A model call that the
    /// repetition watch stopped (``runWatchedModelCall(composedPrompt:_:)``)
    /// goes on in ``continueAfterRepetitionStop(_:attempt:body:)``.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn.
    ///   - pendingEvents: The events this attempt carries in its preamble.
    ///   - ownPrompt: This attempt's own prompt text.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    ///   - allowOverflowRetry: Whether a recoverable context overflow compacts and retries once.
    ///   - rejectedCallRetries: How many rejected tool calls this turn has already sent back to the model. The first attempt of a turn has sent none.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or the retry's own outcome when a retry ran.
    func runTurnAttempt(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        allowOverflowRetry: Bool,
        rejectedCallRetries: Int = 0,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let composedPrompt = Self.composedPrompt(pendingEvents: pendingEvents, prompt: ownPrompt)

        let started = Date()
        let usageBefore = backend.usageTokenCounts()
        // Open for this attempt alone. `finishTurn` closes it on both exits.
        openGenerationCallLedger(usageBefore: usageBefore, responseTokenCeiling: responseTokenCeiling.resolved)
        toolResultWatch.composedPrompt = composedPrompt
        // The facts a compaction inside the turn needs, when the attempt stops
        // at a tool result or at its ceiling. The ledger above set the entry ids.
        let attempt = StoppedAttempt(
            grammar: grammar, composedPrompt: composedPrompt,
            entryIdsBeforeAttempt: toolResultWatch.entryIdsBeforeAttempt, started: started,
            usageBefore: usageBefore, responseTokenCeiling: responseTokenCeiling,
            pendingEvents: pendingEvents, onEvent: onEvent, allowOverflowRetry: allowOverflowRetry,
            rejectedCallRetries: rejectedCallRetries)
        let response: String
        let finishReason: FinishReason
        do {
            // The hard-ceiling pre-check (compaction_plan.md §1.7, task g2hcm36):
            // when the budget opts into ``TokenBudget/hardCeiling``, measured
            // usage is checked *before* `body` ever submits this attempt's
            // generate call — deterministic, so a transcript already too
            // large to fit (typically because the proactive compaction above
            // couldn't bring it down far enough) fails fast rather than
            // wasting a real generation call on a doomed submission. Thrown
            // from inside this `do` block, exactly like a guided turn's
            // pre-flight grammar-validation failure, so it is recorded as any
            // other failed attempt below (zero-delta usage, since `backend`
            // is never touched) and, via ``isRecoverableContextOverflow(_:)``,
            // recovered by the same compact-harder-and-retry-once path as
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
            response = try await runWatchedModelCall(composedPrompt: composedPrompt, body)
            // A turn can succeed (return a response) yet still leave the SDK's
            // transcript unchanged for some future conformer — attach-or-requeue
            // applies uniformly on both exits (see the catch branch's matching
            // comment), not just the throwing one; that uniform check lives in
            // ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:responseTokenCeiling:pendingEvents:onEvent:)``.
            finishReason = await finishTurnAndRequeueIfUnattached(
                grammar: grammar, since: started, usageBefore: usageBefore,
                responseTokenCeiling: responseTokenCeiling.resolved, pendingEvents: pendingEvents, onEvent: onEvent
            ).finishReason
        } catch {
            if let yield = takeCompactionYield() {
                return try await continueAfterCompactionYield(yield, attempt: attempt, body: body)
            }
            if let repetitionStop = takeRepetitionStop() {
                return try await continueAfterRepetitionStop(repetitionStop, attempt: attempt, body: body)
            }
            await recordFailedTurn(
                grammar: grammar, since: started, usageBefore: usageBefore,
                responseTokenCeiling: responseTokenCeiling.resolved, pendingEvents: pendingEvents, onEvent: onEvent)
            return try await recoverFailedAttempt(
                from: error, grammar: grammar, ownPrompt: ownPrompt,
                responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
                allowOverflowRetry: allowOverflowRetry, rejectedCallRetries: rejectedCallRetries, body
            )
        }
        // Outside the `do`: the attempt is recorded, so a failure of the
        // compaction or of the next attempt must not record it a second time.
        guard compactsAfterCeilingStop(finishReason) else { return response }
        return try await continueAfterCeilingStop(attempt: attempt, body: body)
    }

    /// Runs the attempt again after a failed attempt that one of the two
    /// recoveries can mend, or throws the error again.
    ///
    /// - A rejected tool call (``RejectedToolCallRetry``) goes back to the
    ///   model: the next attempt sends the failed prompt again, with a tool
    ///   error that says which call was rejected and why, so the model can
    ///   write the call again. The retries have no count: they continue until
    ///   the model writes a call the parser accepts, the caller cancels the
    ///   turn, or the context fills. Each retry's prompt carries the earlier
    ///   tool errors, so a model that never corrects its call reaches the
    ///   overflow path.
    /// - A recoverable context overflow compacts and retries once, when
    ///   `allowOverflowRetry` is set. ``OverflowRetryTarget`` chooses the
    ///   target. When the caller named a response ceiling, the target is the
    ///   room the turn needs; when the prompt and that ceiling alone fill the
    ///   window, no compaction helps: the turn does not retry, and `error`
    ///   reaches the caller. When the caller named no ceiling, the target is
    ///   the configured target of the budget.
    ///
    /// The caller has already recorded the failed attempt, so the retry
    /// carries no pending events.
    ///
    /// - Parameters:
    ///   - error: The error the failed attempt threw.
    ///   - grammar: The grammar in force for this turn.
    ///   - ownPrompt: The prompt text of the failed attempt.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    ///   - allowOverflowRetry: Whether a recoverable context overflow compacts and retries once.
    ///   - rejectedCallRetries: How many rejected tool calls this turn has already sent back to the model.
    ///   - body: The model work to run.
    /// - Returns: The response text of the retry.
    /// - Throws: `error` when no recovery applies, or the retry's own outcome.
    private func recoverFailedAttempt(
        from error: any Error,
        grammar: Grammar?,
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)?,
        allowOverflowRetry: Bool,
        rejectedCallRetries: Int,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        if let retry = RejectedToolCallRetry(error: error) {
            let ordinal = rejectedCallRetries + 1
            retry.logRetry(sessionID: id, ordinal: ordinal)
            return try await runTurnAttempt(
                grammar: grammar, pendingEvents: [], ownPrompt: retry.prompt(retrying: ownPrompt),
                responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
                allowOverflowRetry: allowOverflowRetry,
                rejectedCallRetries: ordinal, body
            )
        }

        guard allowOverflowRetry, let budget = autoCompactionBudget, Self.isRecoverableContextOverflow(error) else {
            throw error
        }

        let retryTarget = overflowRetryTarget(
            retryPrompt: ownPrompt, requestedResponseTokenCeiling: responseTokenCeiling.requested, budget: budget)
        retryTarget.log(sessionID: id)
        guard retryTarget.leavesRoom else {
            throw error
        }

        let result = try await performAutoCompaction(
            prompt: autoCompactionPrompt, budget: retryTarget.budget(lowering: budget))
        onEvent?(.compaction(result.withOverflowRetryTarget(retryTarget)))

        return try await runTurnAttempt(
            grammar: grammar, pendingEvents: [], ownPrompt: ownPrompt,
            responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
            allowOverflowRetry: false, rejectedCallRetries: rejectedCallRetries, body
        )
    }

    /// Records a turn that ended in a failure: the transcript diff, the
    /// attach-or-requeue of pending events, and a `.response` close when the
    /// diff did not already include one. The close carries an entry that
    /// mirrors a `Transcript.Response` with no segment — the turn answered
    /// with nothing — so the record holds an entry for every turn it closes
    /// (see ``TranscriptEvent/isFailedTurnClose``).
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this turn.
    ///   - started: The turn's start time.
    ///   - usageBefore: The token-usage snapshot taken before the failed work ran.
    ///   - responseTokenCeiling: The token ceiling the turn gave its backend, or `nil`.
    ///   - pendingEvents: The events this turn drained from ``outbox``.
    ///   - onEvent: A sink for this turn's ``SessionEvent``s, or `nil`.
    private func recordFailedTurn(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async {
        let (diffIncludedResponse, usage, _) = await finishTurnAndRequeueIfUnattached(
            grammar: grammar, since: started, usageBefore: usageBefore,
            responseTokenCeiling: responseTokenCeiling, pendingEvents: pendingEvents, onEvent: onEvent)
        guard !diffIncludedResponse else { return }
        let close = TranscriptEntryMapper.event(from: .response(Transcript.Response(segments: [])))
        await append(
            partial: makePartialEvent(
                kind: .response,
                grammar: grammar,
                since: started,
                entry: close.payload,
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
    /// ``CancellableCompactionSummarizer`` also routes a compaction's summarizer call through here.
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
        // A cancellation that landed while this turn held no model call — between two
        // summarizer tiers of a compaction, or between a failed attempt and this
        // retry — had no task to cancel, so it is honored here instead of being
        // dropped, and the model (with every tool call it would make) is never
        // re-entered on behalf of a turn already cancelled.
        if isTurnCancelled {
            throw CancellationError()
        }
        // The host-side ambient binding (task ^k4nygqa): every backend respond()/stream
        // call runs under a ``ToolContext`` carrying this session's
        // identity, its mailbox, and its own `SessionOutbox` as the
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
        // The tool-result append boundary of this model call: each tool result
        // the model reads next goes through it (see ``noteToolResult(_:)``).
        let resultBoundary = ToolResultAppendBoundary(session: self)
        let modelCall = Task {
            try await GenerationPermitLoan.$current.withValue(permitLoan) {
                try await ToolResultAppendBoundary.$current.withValue(resultBoundary) {
                    try await ToolContext.$current.withValue(turnContext) {
                        try await body(composedPrompt)
                    }
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

    /// The compaction target of the retry after a context overflow.
    ///
    /// When the caller named a response ceiling, the rule is
    /// ``OverflowRetryTarget/Rule/callerCeiling(_:)``: the room the window keeps
    /// for the transcript after the retry's prompt and that ceiling. When the
    /// caller named none, the rule is ``OverflowRetryTarget/Rule/configuredTarget``:
    /// the configured target of `budget`.
    ///
    /// The retry's prompt is measured with this session's ``tokenCounter``,
    /// the tokenizer of its model. The retry carries no pending events, so its
    /// composed prompt is `retryPrompt` unchanged.
    ///
    /// - Parameters:
    ///   - retryPrompt: The prompt text the retry sends.
    ///   - requestedResponseTokenCeiling: The response ceiling the caller named, or `nil`.
    ///   - budget: The session's own budget.
    /// - Returns: The target of the retry.
    private func overflowRetryTarget(
        retryPrompt: String, requestedResponseTokenCeiling: Int?, budget: TokenBudget
    ) -> OverflowRetryTarget {
        OverflowRetryTarget(
            rule: requestedResponseTokenCeiling.map(OverflowRetryTarget.Rule.callerCeiling) ?? .configuredTarget,
            contextTokens: contextTokens,
            promptTokens: tokenCounter.count(Self.composedPrompt(pendingEvents: [], prompt: retryPrompt)),
            configuredTargetTokens: budget.targetTokens)
    }

    /// Runs the earliest still-pending queued prompt as one normal recorded turn.
    /// See ``RoutedSession/dispatchNextPrompt()`` for the full contract.
    ///
    /// Dequeues the front prompt and any pending events in one atomic
    /// `SessionOutbox.drainForDispatch()` call, inside the same two gates
    /// ``generate(grammar:entryPoint:prompt:responseTokenCeiling:onEvent:_:)`` uses. Honors ``grammar``. The
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
        await notifyTurnBoundaryTools()
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
        turnId: TurnID, promptId: PromptID?, pendingEvents: [OperationEvent], ownPrompt: String
    ) async throws -> String {
        let outcome: Result<String, any Error>
        let ceiling = ResponseTokenCeiling(requested: nil, contextTokens: contextTokens)
        do {
            outcome = .success(
                try await runTurn(
                    grammar: grammar, turnId: turnId, entryPoint: .dispatch, promptId: promptId,
                    pendingEvents: pendingEvents, ownPrompt: ownPrompt, responseTokenCeiling: ceiling,
                    respondBody(grammar: grammar, responseTokenCeiling: ceiling.resolved)
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
