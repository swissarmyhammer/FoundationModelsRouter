import Foundation
import FoundationModels
import Synchronization
import Tracing
import os

/// The logger for a failed pre-discovery seeding of an answer.
private let sessionPrimingLogger = makeModuleLogger(category: "DiscoveryPriming")

/// ``RoutedSessionActor``'s answer execution: the recorder-bracketed chain of
/// submissions that the pump runs for one answer, discovery priming, the
/// recovery from an overflow or a rejected tool call,
/// and cancellation.
extension RoutedSessionActor {
    /// The token ceiling a submission gives its backend.
    ///
    /// A ceiling the caller names wins. Otherwise the ceiling is the resolved
    /// working context of the session: a response cannot be longer than the
    /// context it decodes in, so the context is the one ceiling that comes from
    /// the model. The length of a submission below that is for the bounds made
    /// to govern it, such as the stall report and a host watchdog, and not for
    /// a constant.
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

    /// Builds the closure that submits the composed prompt of a submission to
    /// `backend`.
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

    /// Calls ``SubmissionBoundaryTool/submissionWillBegin()`` once on every
    /// mounted tool that conforms, in mount order — the clock tick a tool uses
    /// to apply a change it prepared at the side (task w77k41m).
    ///
    /// The session calls it one time before each submission, after it took
    /// the messages of that submission and before its model call. The pump
    /// calls it for the first submission of an answer, before the proactive
    /// compaction, so an answer that fails before the model call still made
    /// the hook call. ``runSubmission(grammar:pendingEvents:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:_:)``
    /// calls it for each continuation submission. A fork's hook fires only on
    /// the fork's own tools (``ForkableTool`` composition).
    func notifySubmissionBoundaryTools() async {
        for tool in tools {
            guard let boundaryTool = tool as? any SubmissionBoundaryTool else { continue }
            await boundaryTool.submissionWillBegin()
        }
    }

    /// Composes the event sink of an answer. Each event goes first to
    /// ``answerReducer``, which makes the ``SessionAnswer`` of the chain. Then
    /// it goes to the own sink of the answer and to the session-scoped
    /// fan-out.
    ///
    /// - Parameter onEvent: The own sink of the answer, or `nil`.
    /// - Returns: The composed sink.
    private func answerEventSink(_ onEvent: ((SessionEvent) -> Void)?) -> (SessionEvent) -> Void {
        { [self] event in
            answerReducer.apply(event)
            onEvent?(event)
            emitSessionScopedEvent(event)
        }
    }

    /// Runs the chain of submissions of one answer. Only the pump calls it,
    /// so no other submission of this session runs meanwhile.
    ///
    /// Every event of the chain goes to the sink of the answer: the stream
    /// of the first message when that message streams events, and
    /// ``RoutedSession/streamSessionEvents()``. The chain ends with
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``.
    /// Each submission of the chain opens its own span (see
    /// `RoutedSessionActorSubmissionEvents.swift`). ``RoutedSession`` states
    /// the span contract, and ``RouterTracing`` states the rule that keeps
    /// content off the spans.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for the answer.
    ///   - pendingEvents: The mail the pump took from ``outbox`` for it.
    ///   - ownPrompt: The prompt text of its caller messages.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: The own sink of the answer for its ``SessionEvent``s, or `nil`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the compaction.
    func runAnswerChain(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let emit = answerEventSink(onEvent)
        answerReducer = SessionAnswerReducer()
        let result: Result<String, any Error>
        do {
            result = .success(
                try await runAnswerWork(
                    grammar: grammar, pendingEvents: pendingEvents, ownPrompt: ownPrompt,
                    responseTokenCeiling: responseTokenCeiling, emit: emit, body))
        } catch {
            result = .failure(error)
        }
        emit(answerEndEvent(for: result))
        return try result.get()
    }

    /// Runs the model work and the recording of one answer. Only
    /// ``runAnswerChain(grammar:pendingEvents:ownPrompt:responseTokenCeiling:onEvent:_:)``
    /// calls it.
    ///
    /// When ``autoCompactionBudget`` is set and measured usage has reached
    /// ``TokenBudget/triggerTokens``, the answer compacts first. A compaction
    /// that throws is recorded as a failed attempt.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for the answer.
    ///   - pendingEvents: The mail the pump took from ``outbox`` for it.
    ///   - ownPrompt: The prompt text of its caller messages.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - emit: The composed sink of the answer (see ``answerEventSink(_:)``).
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the compaction.
    private func runAnswerWork(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        emit: @escaping (SessionEvent) -> Void,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // Installed for exactly this answer's duration so a live
        // ``ToolInvocationRecord`` posted during the answer reaches the answer's
        // own stream — see ``deliver(invocation:)`` and
        // ``RoutedSessionActor/currentAnswerEventSink``.
        currentAnswerEventSink = emit
        defer { currentAnswerEventSink = nil }

        // Compared in tokens against ``TokenBudget/triggerTokens``, never as
        // `contextFill >= budget.trigger` — see the matching note on the
        // hard-ceiling pre-check in
        // ``runSubmission(grammar:pendingEvents:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:_:)``
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
                // answer has not reached `runSubmission`, where a failed
                // submission's recording and the outbox's attach-or-requeue rule
                // both live. So the compaction's failure path has to run them
                // here, or the mail the pump already *destructively* took would
                // be destroyed and the answer would leave no trace at all. Neither is a formality: an
                // abandoned compaction leaves `backend` exactly as it was, so the diff
                // finds no `.prompt` partial to attach those events to and
                // re-queues them, and the synthetic close is the trace.
                await recordFailedSubmission(
                    grammar: grammar, since: started, usageBefore: usageBefore,
                    responseTokenCeiling: responseTokenCeiling.resolved, pendingEvents: pendingEvents, onEvent: emit)
                throw error
            }
        }

        await primeDiscoveryIfConfigured(prompt: ownPrompt, emit: emit)

        return try await runSubmission(
            grammar: grammar, pendingEvents: pendingEvents, ownPrompt: ownPrompt,
            responseTokenCeiling: responseTokenCeiling, onEvent: emit,
            allowOverflowRetry: autoCompactionBudget != nil, body
        )
    }

    /// Seeds the pre-discovery entries of this answer into ``backend`` when ``discoveryPriming`` is set.
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
            // One call, two routes: `emit` is the composed sink of this answer,
            // which already fans out to the own stream of the answer (when the
            // caller sent the message through ``streamEvents(to:maxTokens:)``)
            // *and* to every session-scoped subscription — the route that
            // reaches a subscriber whichever entry point sent the message,
            // including ``respond(to:maxTokens:)``, which hands its caller a
            // response rather than a stream, and ``send(_:)-(Transcript.Prompt)``,
            // which hands its caller nothing but an id (see
            // ``answerEventSink(_:)`` and ``RoutedSession/streamSessionEvents()``).
            emit(.discoveryPrimingFailed(error))
        }
    }

    /// One submission of the answer: one physical attempt at the model work
    /// of the answer, and its recording.
    ///
    /// The attempt opens its submission first
    /// (``beginSubmission(cause:messageIds:)``). The first attempt of an
    /// answer delivers the caller messages of the answer, or mail alone. A
    /// continuation delivers the caller messages that joined it. The
    /// recording of the attempt ends the submission.
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
    ///   - grammar: The grammar in force for this answer.
    ///   - pendingEvents: The events this attempt carries in its preamble.
    ///   - ownPrompt: This attempt's own prompt text.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for the ``SessionEvent``s of this answer, or `nil`.
    ///   - allowOverflowRetry: Whether a recoverable context overflow compacts and retries once.
    ///   - rejectedCallRetries: How many rejected tool calls this answer has already sent back to the model. The first attempt of an answer has sent none.
    ///   - isContinuation: Whether this attempt is a continuation submission
    ///     of the answer. A continuation first takes the messages that wait
    ///     (``takeMessagesJoiningTheAnswer()``): the mail goes into its
    ///     preamble, and each caller prompt that can share the submission
    ///     goes after `ownPrompt`.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or the retry's own outcome when a retry ran.
    func runSubmission(
        grammar: Grammar?,
        pendingEvents: [OperationEvent],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        allowOverflowRetry: Bool,
        rejectedCallRetries: Int = 0,
        isContinuation: Bool = false,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        var pendingEvents = pendingEvents
        var ownPrompt = ownPrompt
        if isContinuation {
            let joining = await takeMessagesJoiningTheAnswer()
            await notifySubmissionBoundaryTools()
            pendingEvents += joining.events
            ownPrompt = ([ownPrompt] + joining.texts).joined(separator: Self.messageSeparator)
            beginSubmission(cause: .continuation, messageIds: joining.ids)
        } else {
            let delivery = firstSubmissionDelivery()
            beginSubmission(cause: delivery.cause, messageIds: delivery.messageIds)
        }
        let composedPrompt = Self.composedPrompt(pendingEvents: pendingEvents, prompt: ownPrompt)

        let started = Date()
        let usageBefore = backend.usageTokenCounts()
        // Open for this attempt alone. `finishSubmission` closes it on both exits.
        openGenerationCallLedger(usageBefore: usageBefore, responseTokenCeiling: responseTokenCeiling.resolved)
        toolResultWatch.composedPrompt = composedPrompt
        // The facts a compaction inside the answer needs, when the attempt stops
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
            // from inside this `do` block, exactly like the pre-flight
            // grammar-validation failure of a guided submission, so it is recorded as any
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
            // A submission can succeed (return a response) yet still leave the SDK's
            // transcript unchanged for some future conformer — attach-or-requeue
            // applies uniformly on both exits (see the catch branch's matching
            // comment), not just the throwing one; that uniform check lives in
            // ``finishSubmissionAndRequeueIfUnattached(grammar:since:usageBefore:responseTokenCeiling:pendingEvents:onEvent:)``.
            finishReason = await finishSubmissionAndRequeueIfUnattached(
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
            recordSubmissionError(error)
            await recordFailedSubmission(
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

    /// Runs one continuation submission of the answer after `attempt`
    /// stopped: a compaction yield, a ceiling stop, or a repetition stop.
    ///
    /// The continuation keeps the grammar, the ceiling, the event sink and
    /// the retry state of `attempt`. It carries none of the mail of
    /// `attempt`, because the stopped attempt is already recorded. It takes
    /// the messages that wait when it starts
    /// (``takeMessagesJoiningTheAnswer()``).
    ///
    /// - Parameters:
    ///   - attempt: The attempt that stopped.
    ///   - continuationPrompt: The own prompt of the continuation.
    ///   - body: The model work to run.
    /// - Returns: The response text of the continuation.
    /// - Throws: What the continuation throws.
    func runContinuation(
        after attempt: StoppedAttempt,
        prompt continuationPrompt: String,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await runSubmission(
            grammar: attempt.grammar, pendingEvents: [], ownPrompt: continuationPrompt,
            responseTokenCeiling: attempt.responseTokenCeiling, onEvent: attempt.onEvent,
            allowOverflowRetry: attempt.allowOverflowRetry, rejectedCallRetries: attempt.rejectedCallRetries,
            isContinuation: true, body)
    }

    /// Runs the attempt again after a failed attempt that one of the two
    /// recoveries can mend, or throws the error again.
    ///
    /// - A rejected tool call (``RejectedToolCallRetry``) goes back to the
    ///   model: the next attempt sends the failed prompt again, with a tool
    ///   error that says which call was rejected and why, so the model can
    ///   write the call again. The retries have no count: they continue until
    ///   the model writes a call the parser accepts, the caller cancels the
    ///   answer, or the context fills. Each retry's prompt carries the earlier
    ///   tool errors, so a model that never corrects its call reaches the
    ///   overflow path.
    /// - A recoverable context overflow compacts and retries once, when
    ///   `allowOverflowRetry` is set. ``OverflowRetryTarget`` chooses the
    ///   target. When the caller named a response ceiling, the target is the
    ///   room the submission needs; when the prompt and that ceiling alone
    ///   fill the window, no compaction helps: the answer does not retry, and
    ///   `error` reaches the caller. When the caller named no ceiling, the
    ///   target is the configured target of the budget.
    ///
    /// The caller has already recorded the failed attempt, so the retry
    /// carries none of its mail. The retry is a continuation: it carries the
    /// messages that wait when it starts.
    ///
    /// - Parameters:
    ///   - error: The error the failed attempt threw.
    ///   - grammar: The grammar in force for this answer.
    ///   - ownPrompt: The prompt text of the failed attempt.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for the ``SessionEvent``s of this answer, or `nil`.
    ///   - allowOverflowRetry: Whether a recoverable context overflow compacts and retries once.
    ///   - rejectedCallRetries: How many rejected tool calls this answer has already sent back to the model.
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
            return try await runSubmission(
                grammar: grammar, pendingEvents: [], ownPrompt: retry.prompt(retrying: ownPrompt),
                responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
                allowOverflowRetry: allowOverflowRetry,
                rejectedCallRetries: ordinal, isContinuation: true, body
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

        return try await runSubmission(
            grammar: grammar, pendingEvents: [], ownPrompt: ownPrompt,
            responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
            allowOverflowRetry: false, rejectedCallRetries: rejectedCallRetries, isContinuation: true, body
        )
    }

    /// Records a submission that ended in a failure: the transcript diff, the
    /// attach-or-requeue of pending events, and a `.response` close when the
    /// diff did not already include one. The close carries an entry that
    /// mirrors a `Transcript.Response` with no segment — the submission
    /// answered with nothing — so the record holds an entry for every
    /// submission it closes (see ``TranscriptEvent/isFailedAnswerClose``).
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this answer.
    ///   - started: The start time of the submission.
    ///   - usageBefore: The token-usage snapshot taken before the failed work ran.
    ///   - responseTokenCeiling: The token ceiling the submission gave its backend, or `nil`.
    ///   - pendingEvents: The events this submission took from ``outbox``.
    ///   - onEvent: A sink for the ``SessionEvent``s of this answer, or `nil`.
    private func recordFailedSubmission(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async {
        let (diffIncludedResponse, usage, _) = await finishSubmissionAndRequeueIfUnattached(
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

    /// The `tool` identity stamped on the ambient ``ToolContext`` binding of a submission.
    private static let submissionBindingToolStamp = "session"

    /// The `op` stamped on the ambient binding of a submission.
    private static let submissionBindingOpStamp = "respond"

    /// Mirrors one model-call task's cancellation into a synchronous probe that
    /// the ambient ``ToolContext`` binding of the submission reports. The unbound window reads `false`.
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

    /// Runs one attempt's model call as one submission of ``backend`` to the
    /// queue of its model, in a task this session can cancel from outside the
    /// pump, and awaits its result.
    ///
    /// The queue and the model are ``ownSubmissionTarget``. See
    /// ``runCancellableModelCall(composedPrompt:submittingTo:_:)``.
    ///
    /// - Parameters:
    ///   - composedPrompt: This attempt's composed prompt, handed to `body`.
    ///   - body: The model work to run: one whole SDK call.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, `CancellationError` when this work
    ///   was already cancelled before its model call started, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    internal func runCancellableModelCall(
        composedPrompt: String,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await runCancellableModelCall(composedPrompt: composedPrompt, submittingTo: ownSubmissionTarget, body)
    }

    /// The queue that each model call of ``backend`` is one submission to, and
    /// this session's model, or `nil` when the backend names no queue.
    var ownSubmissionTarget: SubmissionTarget? {
        backend.generationQueue.map { SubmissionTarget(queue: $0, model: model) }
    }

    /// Runs one model call as one submission to the queue of `target`, in a
    /// task this session can cancel from outside the pump, and awaits its
    /// result (`generation-queue.md`, section 5.3).
    ///
    /// The submission is `body` itself: one whole SDK call, with all of its
    /// passes and tool bodies. The worker of the queue runs it on a task of
    /// its own, which inherits no task-local of this call, so the submission
    /// binds the task-locals of the model call itself (see
    /// ``submission(of:composedPrompt:mark:boundary:context:serviceContext:)``).
    /// Any other task-local of the caller does not reach the tool bodies of a
    /// queued call. With no `target`, the call runs directly, on a task of
    /// its own.
    ///
    /// Cancelling ``inFlightModelCall`` removes a submission that still waits
    /// for the worker, or unwinds `body` and every in-band tool call under it.
    /// A background run keeps running in the session's ``mailbox``. The
    /// recording of the submission runs after this returns or throws and is
    /// never cancelled. ``CancellableCompactionSummarizer`` also routes a
    /// compaction's summarizer call through here, to the queue of the
    /// container that runs it.
    ///
    /// - Parameters:
    ///   - composedPrompt: This attempt's composed prompt, handed to `body`.
    ///   - target: The queue the call is one submission to, and its model, or
    ///     `nil` to run the call directly.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, `CancellationError` when this work
    ///   was already cancelled before its model call started or while its
    ///   submission waited, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when this
    ///   call comes from inside an open submission on the same queue.
    internal func runCancellableModelCall(
        composedPrompt: String,
        submittingTo target: SubmissionTarget?,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // A cancellation that landed while this work held no model call — between two
        // summarizer tiers of a compaction, or between a failed attempt and this
        // retry — had no task to cancel, so it is honored here instead of being
        // dropped, and the model (with every tool call it would make) is never
        // re-entered on behalf of work already cancelled.
        if isWorkCancelled {
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
        let ambientToolContext = ToolContext(
            sessionID: id,
            mailbox: mailbox,
            sink: outbox,
            tool: Self.submissionBindingToolStamp,
            op: Self.submissionBindingOpStamp,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { cancellationProbe.isCancelled }
        )
        // The mark of this model call, published for exactly this call. A tool
        // the model invokes from inside the call reads it, so a wait for an
        // answer of this same session, or a submission to the same queue, is
        // refused at once rather than parked behind this submission, which
        // waits for the tool. Closed in the `defer` below, so a task that
        // outlives the call is in no model call of this session. See
        // ``ModelCallMark``.
        let modelCallMark = ModelCallMark(sessionID: id, submission: target)
        defer { modelCallMark.close() }
        // The stall watch (task ^z6xcmnh), opened before the call and closed
        // by its own `defer`. It bounds nothing: the watchdog only reports a
        // ``GenerationStall`` on each interval the call goes without observable
        // progress, so a decode that stops making progress becomes visible
        // while it is still running instead of only when it finally ends. See
        // ``RoutedSessionActor/reportGenerationStall(id:)``. The phase reports
        // of this call (tasks ^ake8sax and ^1psqdm9) feed the same watch, so
        // it counts only the time inside a pass of the running submission, and
        // they tell the consumer about the wait and the start of the
        // submission. They close first, so the last reports reach the watch
        // and the answer before the watch ends.
        let stallWatchId = beginGenerationStallWatch(submitsToQueue: target != nil)
        let passReports = openGenerationPassReports(callID: stallWatchId)
        let stallWatchdog = Task { await self.watchGenerationForStalls(id: stallWatchId) }
        defer {
            closeGenerationPassReports(callID: stallWatchId, reader: passReports)
            stallWatchdog.cancel()
            endGenerationStallWatch(id: stallWatchId)
        }
        // The tool-result append boundary of this model call: each tool result
        // the model reads next goes through it (see ``noteToolResult(_:)``).
        let submission = Self.submission(
            of: body, composedPrompt: composedPrompt, mark: modelCallMark,
            boundary: ToolResultAppendBoundary(session: self), context: ambientToolContext,
            serviceContext: submissionServiceContext)
        let observer = generationPassObserver
        let modelCall = Task {
            try await Self.run(
                submission, on: target?.queue, reportingTo: observer,
                onStart: { await self.submissionDidStart() })
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

    /// The submission of one model call: `body` over `composedPrompt`, with
    /// the task-locals of the call bound around it.
    ///
    /// The worker of a queue runs the submission on a task that inherits no
    /// task-local of the session, so the submission binds each one itself.
    /// The SDK gives them to each tool body it runs inside the call. The
    /// tracing `ServiceContext` of the submission is one of them, so the span
    /// of each tool call stays a child of the span of its submission.
    ///
    /// - Parameters:
    ///   - body: The model work: one whole SDK call.
    ///   - composedPrompt: The composed prompt of the attempt.
    ///   - mark: The mark of the model call.
    ///   - boundary: The tool-result append boundary of the model call.
    ///   - context: The ambient ``ToolContext`` of the model call.
    ///   - serviceContext: The tracing context of the submission
    ///     (``submissionServiceContext``), or `nil`.
    /// - Returns: The submission.
    private static func submission(
        of body: @escaping @Sendable (String) async throws -> String,
        composedPrompt: String,
        mark: ModelCallMark,
        boundary: ToolResultAppendBoundary,
        context: ToolContext,
        serviceContext: ServiceContext?
    ) -> @Sendable () async throws -> String {
        {
            try await ServiceContext.$current.withValue(serviceContext) {
                try await ModelCallMark.$current.withValue(mark) {
                    try await ToolResultAppendBoundary.$current.withValue(boundary) {
                        try await ToolContext.$current.withValue(context) {
                            try await body(composedPrompt)
                        }
                    }
                }
            }
        }
    }

    /// Runs `submission` as one item of `queue`, and reports its wait and its
    /// start to `observer`, or runs it directly when there is no queue.
    ///
    /// `onStart` runs first, before `submission`, in both cases. It hops to
    /// the actor and calls ``submissionDidStart()``, which sends
    /// ``SessionEvent/submissionStarted(_:)``. That call applies the reported
    /// phases first, so a ``SessionEvent/submissionQueued(_:)`` of the
    /// submission always comes before its start. Because `submission` starts
    /// only after `onStart` returns, no content of the submission comes before
    /// its start.
    ///
    /// - Parameters:
    ///   - submission: The submission of one model call.
    ///   - queue: The queue of the model, or `nil`.
    ///   - observer: The observer of this session's model calls.
    ///   - onStart: The closure that reports the start of the submission. It
    ///     runs at the start of the queue item, or before the direct call.
    /// - Returns: What `submission` returns.
    /// - Throws: What the queue or `submission` throws.
    private static func run(
        _ submission: @escaping @Sendable () async throws -> String,
        on queue: GenerationQueue?,
        reportingTo observer: GenerationPassObserver,
        onStart: @escaping @Sendable () async -> Void
    ) async throws -> String {
        guard let queue else {
            await onStart()
            return try await submission()
        }
        return try await queue.submit(onQueued: { observer.submissionQueued() }) {
            observer.submissionStarted()
            await onStart()
            return try await submission()
        }
    }

    /// Whether a cancellation is outstanding against the work the pump runs,
    /// by any route: `Task.isCancelled` of the task that reads it,
    /// ``cancelRequestedWorkId`` set for that work by
    /// ``requestCancelOfRunningWork()`` (``RoutedSession/cancel()``,
    /// or the cancel of a caller whose message the work carries), or the
    /// cancel mark of a message the running answer delivered
    /// (``PumpAnswer/requestCancel()``). This is the one read site of
    /// ``cancelRequestedWorkId``, so the routes cannot diverge. Every cancel
    /// decision keys on this predicate, never on the type of a
    /// `CancellationError`. Read after each `await`; do not cache.
    ///
    /// The mark is necessary. A cancelled caller task sets the mark at once,
    /// in its cancellation handler, but it asks for
    /// ``cancel(message:)`` in a task of its own that must get this actor.
    /// The pump can get the actor first, for example after a failed attempt,
    /// and start the overflow retry before ``cancelRequestedWorkId`` is set.
    /// The mark closes that window: a delivered message with the mark is the
    /// case where ``cancel(message:)`` stops this work, so the result is the
    /// same, only earlier. The read is an atomic load, with no lock and no
    /// suspension point.
    var isWorkCancelled: Bool {
        if Task.isCancelled { return true }
        guard let workId = pumpWork?.id else { return false }
        if cancelRequestedWorkId == workId { return true }
        return deliveredMessages?.contains(where: \.answer.isCancelRequested) == true
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

    /// Composes a submission's model-visible prompt: `pendingEvents` rendered as a
    /// plain-text preamble (see ``OperationEventSegment/renderedLine(for:)``), a blank
    /// line, then `prompt`. Returns `prompt` unchanged when `pendingEvents` is empty.
    private static func composedPrompt(pendingEvents: [OperationEvent], prompt: String) -> String {
        guard !pendingEvents.isEmpty else { return prompt }
        let preamble = pendingEvents.map(OperationEventSegment.renderedLine(for:)).joined(separator: "\n")
        return preamble + "\n\n" + prompt
    }
}
