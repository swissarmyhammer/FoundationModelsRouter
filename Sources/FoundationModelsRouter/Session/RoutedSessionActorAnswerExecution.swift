import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Tracing
import Logging

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
    /// a constant. The one bound of that kind is the pass token limit of the
    /// repetition watch, which ``ResponseTokenCeiling`` applies to this value
    /// (task ^dzw15st).
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
    ///     ``ResponseTokenCeiling/resolved`` gives it.
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

    /// Calls `SubmissionBoundaryTool.submissionWillBegin()` once on every
    /// mounted tool that conforms, in mount order — the clock tick a tool uses
    /// to apply a change it prepared at the side (task w77k41m).
    ///
    /// The session calls it one time before each submission, after it took
    /// the messages of that submission and before its model call. The pump
    /// calls it for the first submission of an answer, before the proactive
    /// compaction, so an answer that fails before the model call still made
    /// the hook call. ``runSubmission(grammar:deliveredMail:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:reasoningOff:_:)``
    /// calls it for each continuation submission.
    func notifySubmissionBoundaryTools() async {
        for tool in tools {
            guard let boundaryTool = tool as? any SubmissionBoundaryTool else { continue }
            await boundaryTool.submissionWillBegin()
        }
    }

    /// Composes the event sink of an answer. Each event goes first to
    /// ``answerReducer``, which makes the ``SessionAnswer`` of the chain. Then
    /// it goes to the output of the session (``emitSessionScopedEvent(_:)``),
    /// where each mail subscription of the answer reads it.
    ///
    /// - Returns: The composed sink.
    private func answerEventSink() -> (SessionEvent) -> Void {
        { [self] event in
            answerReducer.apply(event)
            // The audience is the mail of this answer, so the events of a
            // compaction inside it, with the origin of their own signal,
            // also reach the readers of that mail.
            emitSessionScopedEvent(event, audience: Set(openAnswerMail.all))
        }
    }

    /// Runs the chain of submissions of one answer. Only the pump calls it,
    /// so no other submission of this session runs meanwhile.
    ///
    /// Every event of the chain goes to the output of the session
    /// (``RoutedSession/streamSessionEvents()``, and each mail subscription
    /// whose mail the answer carries). The chain starts with one
    /// ``SessionEvent/mailDelivered(_:)`` for each mail of the batch, and it
    /// ends with ``SessionEvent/answered(_:)`` or
    /// ``SessionEvent/answerFailed(_:)``, the terminal event of each mail
    /// that the answer delivered (``emitAnswerEnd(for:)``). Each submission
    /// of the chain opens its own span (see
    /// `RoutedSessionActorSubmissionEvents.swift`). ``RoutedSession`` states
    /// the span contract, and ``RouterTelemetry`` states the rule that keeps
    /// content off the spans.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for the answer.
    ///   - deliveredMail: The mail the pump took from ``outbox`` for it, in
    ///     take order: user-type mail and run mail.
    ///   - ownPrompt: The prompt text of its user-type mail, or the prompt of
    ///     the pump for a batch that only run mail starts.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - body: The model work to run.
    func runAnswerChain(
        grammar: Grammar?,
        deliveredMail: [Mail],
        ownPrompt: String,
        responseTokenCeiling: ResponseTokenCeiling,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async {
        let emit = answerEventSink()
        answerReducer = SessionAnswerReducer()
        // The model sees each mail of the answer from now on. The delivery
        // comes before each other event of the answer.
        for mailID in deliveredMailIds {
            emit(.mailDelivered(mailID))
        }
        let result: Result<String, any Error>
        do {
            result = .success(
                try await runAnswerWork(
                    grammar: grammar, deliveredMail: deliveredMail, ownPrompt: ownPrompt,
                    responseTokenCeiling: responseTokenCeiling, emit: emit, body))
        } catch {
            result = .failure(error)
        }
        // The end of the answer is the terminal event of each mail that the
        // answer delivered, also of mail that joined a continuation, so its
        // origin holds each of them.
        OriginContext.$current.withValue(Self.origin(adding: deliveredMailIds)) {
            emitAnswerEnd(for: result)
        }
    }

    /// Runs the model work and the recording of one answer. Only
    /// ``runAnswerChain(grammar:deliveredMail:ownPrompt:responseTokenCeiling:_:)``
    /// calls it.
    ///
    /// When ``autoCompactionBudget`` is set and measured usage has reached
    /// ``TokenBudget/triggerTokens``, the answer compacts first. A compaction
    /// that throws is recorded as a failed attempt.
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for the answer.
    ///   - deliveredMail: The mail the pump took from ``outbox`` for it, in
    ///     take order.
    ///   - ownPrompt: The prompt text of its user-type mail.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - emit: The composed sink of the answer (see ``answerEventSink()``).
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or `CancellationError` from the compaction.
    private func runAnswerWork(
        grammar: Grammar?,
        deliveredMail: [Mail],
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
        // A compaction that runs ends first, so the trigger check below and
        // the render of the first submission use the compacted value.
        await awaitActiveCompaction()

        // Compared in tokens against ``TokenBudget/triggerTokens``, never as
        // `contextFill >= budget.trigger` — see the matching note on the
        // hard-ceiling pre-check in
        // ``runSubmission(grammar:deliveredMail:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:reasoningOff:_:)``
        // and ``TokenBudget/triggerTokens`` itself for why those two fractions
        // are not interchangeable.
        if let budget = autoCompactionBudget,
            let measuredTokens = usageState.measuredTokens,
            measuredTokens >= budget.triggerTokens
        {
            let started = Date()
            let usageBefore = backend.usageTokenCounts()
            do {
                try await compactInsideAnswer(
                    prompt: autoCompactionPrompt, budget: budget, reason: .triggerReached)
            } catch {
                // A compaction can throw — a summarizer failure, or
                // `CancellationError` when the answer was stopped before the
                // compaction started or close cancelled it — and this
                // answer has not reached `runSubmission`, where a failed
                // submission's recording and the outbox's attach-or-requeue rule
                // both live. So the compaction's failure path has to run them
                // here, or the mail the pump already *destructively* took would
                // be destroyed and the answer would leave no trace at all. Neither is a formality: an
                // abandoned compaction leaves `backend` exactly as it was, so the diff
                // finds no `.prompt` partial to attach the records of that mail to and
                // re-queues its run mail, and the synthetic close is the trace.
                // No attempt ran, so no entry of the backend is a prompt of
                // this answer: each entry counts as one from before.
                await recordFailedSubmission(
                    grammar: grammar, since: started, usageBefore: usageBefore,
                    responseTokenCeiling: responseTokenCeiling.resolved, deliveredMail: deliveredMail,
                    entryIdsBeforeAttempt: Set(backend.transcriptEntries().map(\.id)), onEvent: emit)
                throw error
            }
        }

        await primeDiscoveryIfConfigured(prompt: ownPrompt, emit: emit)

        return try await runSubmission(
            grammar: grammar, deliveredMail: deliveredMail, ownPrompt: ownPrompt,
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
            sessionLogger(.discoveryPriming).warning(
                "generating unseeded: the discovery priming failed",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)"
                ]) { _, new in new })
            // `emit` is the composed sink of this answer: it goes to the
            // output of the session, so each mail subscription of the answer
            // and each ``RoutedSession/streamSessionEvents()`` feed gets it,
            // whichever helper sent the mail (see ``answerEventSink()``).
            emit(.discoveryPrimingFailed(error))
        }
    }

    /// One submission of the answer: one physical attempt at the model work
    /// of the answer, and its recording.
    ///
    /// The attempt opens its submission first
    /// (``beginSubmission(cause:mailIds:)``). The first attempt of an
    /// answer delivers all mail of the batch: user-type mail and run mail. A
    /// continuation delivers the mail that joined it. The
    /// recording of the attempt ends the submission.
    ///
    /// A failed attempt is recorded, and then
    /// ``recoverFailedAttempt(_:carrying:sessionText:settings:_:)``
    /// runs the attempt again when a recovery applies
    /// (``plannedRecovery(after:retryPrompt:settings:)``): a rejected tool call
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
    /// goes on in ``continueAfterWatchStop(_:attempt:body:)``. An attempt
    /// that ended inside its reasoning with no tool call and no text
    /// (``reasoningEndStop(finishReason:attempt:)``) goes on in
    /// ``continueAfterReasoningEnd(_:attempt:body:)`` (task ^hm9trt5).
    ///
    /// - Parameters:
    ///   - grammar: The grammar in force for this answer.
    ///   - deliveredMail: The mail this attempt delivers, in take order. For a
    ///     continuation, it is the user-type mail that a retry carries from
    ///     the failed attempt (``recoverFailedAttempt(_:carrying:sessionText:settings:_:)``),
    ///     and it is empty for the other continuations.
    ///   - ownPrompt: This attempt's own prompt text, or `nil` when the
    ///     prompt of the attempt is only the render of its mail.
    ///   - responseTokenCeiling: The token ceiling `body` gives the backend, and the ceiling the caller named.
    ///   - onEvent: A sink for the ``SessionEvent``s of this answer, or `nil`.
    ///   - allowOverflowRetry: Whether a recoverable context overflow compacts and retries once.
    ///   - rejectedCallRetries: How many rejected tool calls this answer has already sent back to the model. The first attempt of an answer has sent none.
    ///   - isContinuation: Whether this attempt is a continuation submission
    ///     of the answer. A continuation first takes the messages that wait
    ///     (``takeMailJoiningTheAnswer()``), and they join `deliveredMail`
    ///     after the mail that it already holds.
    ///     The prompt of a submission is the render of its mail in take order
    ///     (``ContextRenderer/promptText(delivering:followedBy:)``), then
    ///     `ownPrompt`. The first submission of an answer that delivers
    ///     user-type mail has no `ownPrompt` after its mail: its `ownPrompt`
    ///     is the text of that mail.
    ///   - reasoningOff: Whether the first pass of the model call of this
    ///     attempt runs with the reasoning of the model off
    ///     (``ReasoningOffRequest``, tasks ^0dcsd3t and ^bhdj5v9). Only that
    ///     pass does: a later pass of its tool loop reasons, and a later
    ///     submission of the answer gets `body` as it is.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or the retry's own outcome when a retry ran.
    func runSubmission(
        grammar: Grammar?,
        deliveredMail: [Mail],
        ownPrompt: String?,
        responseTokenCeiling: ResponseTokenCeiling,
        onEvent: ((SessionEvent) -> Void)? = nil,
        allowOverflowRetry: Bool,
        rejectedCallRetries: Int = 0,
        isContinuation: Bool = false,
        reasoningOff: Bool = false,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        // The next render of the answer uses the compacted value of a
        // compaction that runs. The answer holds no open submission while it
        // waits, so the compaction never waits for it.
        await awaitActiveCompaction()
        let attempt = SubmissionAttemptState(
            grammar: grammar, responseTokenCeiling: responseTokenCeiling, onEvent: onEvent,
            allowOverflowRetry: allowOverflowRetry, rejectedCallRetries: rejectedCallRetries,
            reasoningOff: reasoningOff)
        guard isContinuation else {
            let delivery = firstSubmissionDelivery()
            beginSubmission(cause: delivery.cause, mailIds: delivery.mailIds)
            // With user-type mail, `ownPrompt` is the text of that mail, and
            // the render of the mail already holds it.
            let sessionText = deliveredMail.contains(where: \.isUserMail) ? nil : ownPrompt
            return try await runOpenedSubmission(attempt, deliveredMail: deliveredMail, sessionText: sessionText, body)
        }
        let joining = takeMailJoiningTheAnswer()
        await notifySubmissionBoundaryTools()
        let joiningIds = joining.map(\.id)
        // Mail that joins the answer adds its id to the origin of the rest of
        // the answer, and the model sees it from this submission on.
        return try await OriginContext.$current.withValue(Self.origin(adding: joiningIds)) {
            for mailID in joiningIds {
                onEvent?(.mailDelivered(mailID))
            }
            beginSubmission(cause: .continuation, mailIds: joiningIds)
            // The mail that a retry carries was taken first, so it comes
            // first: the records and the render keep the take order.
            return try await runOpenedSubmission(
                attempt, deliveredMail: deliveredMail + joining, sessionText: ownPrompt, body)
        }
    }

    /// The origin of the work that runs now, with the mail `mailIds` added:
    /// the origin of the rest of an answer that this mail joined.
    ///
    /// - Parameter mailIds: The correlation ids of the joining mail.
    /// - Returns: ``OriginContext/current`` when `mailIds` is empty, and else
    ///   ``Origin/mail(_:)`` with the ids of the current origin and `mailIds`.
    static func origin(adding mailIds: [MailID]) -> Origin {
        guard !mailIds.isEmpty else { return OriginContext.current }
        guard case .mail(let ids) = OriginContext.current else { return .mail(Set(mailIds)) }
        return .mail(ids.union(mailIds))
    }

    /// The settings of one submission attempt that
    /// ``runSubmission(grammar:deliveredMail:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:reasoningOff:_:)``
    /// gives to ``runOpenedSubmission(_:deliveredMail:sessionText:_:)``.
    private struct SubmissionAttemptState {
        /// The grammar in force for this answer.
        let grammar: Grammar?

        /// The token ceiling the body gives the backend, and the ceiling the
        /// caller named.
        let responseTokenCeiling: ResponseTokenCeiling

        /// A sink for the ``SessionEvent``s of this answer, or `nil`.
        let onEvent: ((SessionEvent) -> Void)?

        /// Whether a recoverable context overflow compacts and retries once.
        let allowOverflowRetry: Bool

        /// How many rejected tool calls this answer has already sent back to
        /// the model.
        let rejectedCallRetries: Int

        /// Whether the first pass of the model call runs with the reasoning
        /// of the model off.
        let reasoningOff: Bool
    }

    /// Runs one submission attempt that
    /// ``runSubmission(grammar:deliveredMail:ownPrompt:responseTokenCeiling:onEvent:allowOverflowRetry:rejectedCallRetries:isContinuation:reasoningOff:_:)``
    /// opened (``beginSubmission(cause:mailIds:)``): the model call, its
    /// recording, and the recovery or the continuation after it.
    ///
    /// - Parameters:
    ///   - settings: The settings of the attempt.
    ///   - deliveredMail: The mail this attempt delivers, in take order.
    ///   - sessionText: The text that the session adds after the mail, or
    ///     `nil`. The prompt the model reads is the render of
    ///     `deliveredMail`, then this text
    ///     (``ContextRenderer/promptText(delivering:followedBy:)``). A
    ///     recovery that runs the attempt again sends this text again.
    ///   - body: The model work to run.
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, or the retry's own outcome when a retry ran.
    private func runOpenedSubmission(
        _ settings: SubmissionAttemptState,
        deliveredMail: [Mail],
        sessionText: String?,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let grammar = settings.grammar
        let responseTokenCeiling = settings.responseTokenCeiling
        let onEvent = settings.onEvent
        let allowOverflowRetry = settings.allowOverflowRetry
        let rejectedCallRetries = settings.rejectedCallRetries
        let reasoningOff = settings.reasoningOff
        let composedPrompt = ContextRenderer.promptText(delivering: deliveredMail, followedBy: sessionText)

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
            deliveredMail: deliveredMail, onEvent: onEvent, allowOverflowRetry: allowOverflowRetry,
            rejectedCallRetries: rejectedCallRetries)
        let response: String
        let finishReason: FinishReason
        do {
            // The hard-ceiling pre-check (task g2hcm36):
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
            response = try await runWatchedModelCall(
                composedPrompt: composedPrompt, reasoningOff ? ReasoningOffRequest.requested(around: body) : body)
            // A submission can succeed (return a response) yet still leave the SDK's
            // transcript unchanged for some future conformer — attach-or-requeue
            // applies uniformly on both exits (see the catch branch's matching
            // comment), not just the throwing one; that uniform check lives in
            // ``finishSubmissionAndRequeueIfUnattached(grammar:since:usageBefore:responseTokenCeiling:deliveredMail:onEvent:stopReason:replacedBackend:)``.
            finishReason = await finishSubmissionAndRequeueIfUnattached(
                grammar: grammar, since: started, usageBefore: usageBefore,
                responseTokenCeiling: responseTokenCeiling.resolved, deliveredMail: deliveredMail,
                entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, onEvent: onEvent
            ).finishReason
        } catch {
            // Taken first, so that each failure clears it. Another stop of
            // the attempt wins over it, and the hint stays due.
            let hintStop = takeDelegationHintStop()
            if let noOpStop = takeNoOpToolCallStop() {
                if hintStop != nil { releaseDelegationHint() }
                return try await continueAfterNoOpToolCallStop(noOpStop, attempt: attempt, body: body)
            }
            if let yield = takeCompactionYield() {
                if hintStop != nil { releaseDelegationHint() }
                return try await continueAfterCompactionYield(yield, attempt: attempt, body: body)
            }
            if let watchStop = takeWatchStop() {
                if hintStop != nil { releaseDelegationHint() }
                return try await continueAfterWatchStop(watchStop, attempt: attempt, body: body)
            }
            if let hintStop {
                return try await continueAfterDelegationHint(hintStop, attempt: attempt, body: body)
            }
            recordSubmissionError(error)
            // The retry delivers the user-type mail and the catalog-change
            // mail of this attempt again (neither goes back to the queue), and
            // its join takes the run mail again. So only the prompt of the
            // retry records that mail, and the transcript holds each mail one
            // time, on the prompt that the model reads at last.
            let carriedMail = deliveredMail.filter { !$0.isRunMail }
            let recovery = plannedRecovery(
                after: error,
                retryPrompt: ContextRenderer.promptText(delivering: carriedMail, followedBy: sessionText),
                settings: settings)
            await recordFailedSubmission(
                grammar: grammar, since: started, usageBefore: usageBefore,
                responseTokenCeiling: responseTokenCeiling.resolved,
                deliveredMail: recovery == nil ? deliveredMail : [],
                entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, onEvent: onEvent)
            guard let recovery else { throw error }
            await requeueUndeliveredRunMail(deliveredMail)
            return try await recoverFailedAttempt(
                recovery, carrying: carriedMail, sessionText: sessionText, settings: settings, body)
        }
        // Outside the `do`: the attempt is recorded, so a failure of the
        // compaction or of the next attempt must not record it a second time.
        if let reasoningStop = reasoningEndStop(finishReason: finishReason, attempt: attempt) {
            return try await continueAfterReasoningEnd(reasoningStop, attempt: attempt, body: body)
        }
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
    /// (``takeMailJoiningTheAnswer()``).
    ///
    /// - Parameters:
    ///   - attempt: The attempt that stopped.
    ///   - continuationPrompt: The own prompt of the continuation.
    ///   - reasoningOff: Whether the first pass of the model call of the
    ///     continuation runs with the reasoning of the model off: `true` for
    ///     a recovery after a reasoning stop or a repetition stop, and for
    ///     the final pass (tasks ^0dcsd3t and ^bhdj5v9).
    ///   - body: The model work to run.
    /// - Returns: The response text of the continuation.
    /// - Throws: What the continuation throws.
    func runContinuation(
        after attempt: StoppedAttempt,
        prompt continuationPrompt: String,
        reasoningOff: Bool = false,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        try await runSubmission(
            grammar: attempt.grammar, deliveredMail: [], ownPrompt: continuationPrompt,
            responseTokenCeiling: attempt.responseTokenCeiling, onEvent: attempt.onEvent,
            allowOverflowRetry: attempt.allowOverflowRetry, rejectedCallRetries: attempt.rejectedCallRetries,
            isContinuation: true, reasoningOff: reasoningOff, body)
    }

    /// A recovery that runs a failed attempt again
    /// (``plannedRecovery(after:retryPrompt:settings:)``).
    private enum AttemptRecovery {
        /// The rejected tool call goes back to the model.
        case rejectedCall(RejectedToolCallRetry)

        /// The context overflow compacts to the target, and the attempt runs
        /// one more time.
        case contextOverflow(OverflowRetryTarget, budget: TokenBudget)
    }

    /// The recovery that mends a failed attempt, or `nil` when no recovery
    /// applies and the error goes to the caller.
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
    /// The plan comes before the record of the failed attempt, because the
    /// record of the mail goes on the prompt of the retry when a retry runs.
    ///
    /// - Parameters:
    ///   - error: The error the failed attempt threw.
    ///   - retryPrompt: The prompt of the retry with no joining mail: the
    ///     render of the mail it carries, then the text of the session.
    ///   - settings: The settings of the failed attempt.
    /// - Returns: The recovery, or `nil`.
    private func plannedRecovery(
        after error: any Error, retryPrompt: String, settings: SubmissionAttemptState
    ) -> AttemptRecovery? {
        if let retry = RejectedToolCallRetry(error: error) {
            return .rejectedCall(retry)
        }
        guard settings.allowOverflowRetry, let budget = autoCompactionBudget, Self.isRecoverableContextOverflow(error)
        else {
            return nil
        }
        let retryTarget = overflowRetryTarget(
            retryPrompt: retryPrompt, requestedResponseTokenCeiling: settings.responseTokenCeiling.requested,
            budget: budget)
        retryTarget.log(sessionID: id, to: sessionLogger(.overflowRetry))
        guard retryTarget.leavesRoom else { return nil }
        return .contextOverflow(retryTarget, budget: budget)
    }

    /// Runs the attempt again after a failed attempt that `recovery` mends.
    ///
    /// The caller has already recorded the failed attempt with no record of
    /// its mail, and has put its run mail back in the queue. The retry is a
    /// continuation: it carries the user-type mail of the failed attempt
    /// (`carriedMail`), and it takes the mail that waits when it starts, the
    /// run mail of the failed attempt too. Its prompt renders all of that
    /// mail, and its `.prompt` entry records it, so each mail has one
    /// delivered record, on the prompt that the model reads at last.
    ///
    /// - Parameters:
    ///   - recovery: The recovery that applies.
    ///   - carriedMail: The user-type mail of the failed attempt, in take order.
    ///   - sessionText: The text that the session added after the mail of
    ///     the failed attempt, or `nil`.
    ///   - settings: The settings of the failed attempt.
    ///   - body: The model work to run.
    /// - Returns: The response text of the retry.
    /// - Throws: What the compaction or the retry throws.
    private func recoverFailedAttempt(
        _ recovery: AttemptRecovery,
        carrying carriedMail: [Mail],
        sessionText: String?,
        settings: SubmissionAttemptState,
        _ body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        switch recovery {
        case .rejectedCall(let retry):
            let ordinal = settings.rejectedCallRetries + 1
            retry.logRetry(sessionID: id, ordinal: ordinal, to: sessionLogger(.rejectedToolCall))
            return try await runSubmission(
                grammar: settings.grammar, deliveredMail: carriedMail, ownPrompt: retry.prompt(retrying: sessionText),
                responseTokenCeiling: settings.responseTokenCeiling, onEvent: settings.onEvent,
                allowOverflowRetry: settings.allowOverflowRetry,
                rejectedCallRetries: ordinal, isContinuation: true, body
            )
        case .contextOverflow(let retryTarget, let budget):
            try await compactInsideAnswer(
                prompt: autoCompactionPrompt, budget: retryTarget.budget(lowering: budget), reason: .contextOverflow,
                overflowRetryTarget: retryTarget)
            return try await runSubmission(
                grammar: settings.grammar, deliveredMail: carriedMail, ownPrompt: sessionText,
                responseTokenCeiling: settings.responseTokenCeiling, onEvent: settings.onEvent,
                allowOverflowRetry: false, rejectedCallRetries: settings.rejectedCallRetries, isContinuation: true, body
            )
        }
    }

    /// Records a submission that ended in a failure: the transcript diff, the
    /// attach-or-requeue of its delivered mail, and a `.response` close when the
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
    ///   - deliveredMail: The mail this submission took from ``outbox``, in
    ///     take order.
    ///   - entryIdsBeforeAttempt: The ids of the backend entries from before
    ///     the failed attempt. The records of `deliveredMail` go only on the
    ///     `.prompt` entry that the attempt itself wrote.
    ///   - onEvent: A sink for the ``SessionEvent``s of this answer, or `nil`.
    private func recordFailedSubmission(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        deliveredMail: [Mail],
        entryIdsBeforeAttempt: Set<String>,
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async {
        let (diffIncludedResponse, usage, _) = await finishSubmissionAndRequeueIfUnattached(
            grammar: grammar, since: started, usageBefore: usageBefore,
            responseTokenCeiling: responseTokenCeiling, deliveredMail: deliveredMail,
            entryIdsBeforeAttempt: entryIdsBeforeAttempt, onEvent: onEvent)
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
    /// ``submission(of:composedPrompt:mark:boundary:checks:context:serviceContext:origin:callerWork:session:)``).
    /// Any other task-local of the caller does not reach the tool bodies of a
    /// queued call. With no `target`, the call runs directly, on a task of
    /// its own.
    ///
    /// Cancelling ``inFlightModelCall`` removes a submission that still waits
    /// for the worker, or unwinds `body` and every in-band tool call under it.
    /// A background run keeps running in the session's ``runPlane``. The
    /// recording of the submission runs after this returns or throws and is
    /// never cancelled.
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
        // A cancellation that landed while this work held no model call —
        // between a failed attempt and this retry — had no task to cancel, so
        // it is honored here instead of being dropped, and the model (with
        // every tool call it would make) is never re-entered on behalf of
        // work already cancelled.
        if isWorkCancelled {
            throw CancellationError()
        }
        // The host-side ambient binding (task ^k4nygqa): every backend respond()/stream
        // call runs under a ``ToolContext`` carrying this session's
        // identity, its run plane, and its own `SessionOutbox` as the
        // upstream sink — so a tool Apple's runtime invokes from inside the
        // model call sees the same ambient capabilities the mounting
        // engine binds per call. Whether the runtime actually propagates
        // task locals into `Tool.call` is the propagation probe's question;
        // this binding is correct either way, and the run-to-completion and
        // background runners of the Extras tool hosting also bind per call
        // regardless. The `completionToken` is minted fresh
        // per model call — run scope, never session scope — and the
        // cancellation probe mirrors this very model-call task's
        // cancellation (bound just after creation, because the context must
        // exist before the task it probes).
        let cancellationProbe = ModelCallCancellationProbe()
        let ambientToolContext = ToolContext(
            sessionID: id,
            runPlane: runPlane,
            sink: outbox,
            tool: Self.submissionBindingToolStamp,
            op: Self.submissionBindingOpStamp,
            completionToken: RunPlane.makeCompletionToken(),
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
        // The origin of the work that makes this call. The worker task of the
        // queue inherits no task-local, so the submission and the report of
        // its start bind it again, and each event of the call keeps it.
        let origin = OriginContext.current
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
        // and the answer before the watch ends. The watchdog and the reader
        // of the reports are helper tasks (``helperTasks``): the call cancels
        // them and does not wait, and the drain of ``close()`` waits until
        // they ended.
        let stallWatchId = beginGenerationStallWatch(submitsToQueue: target != nil)
        let passReports = openGenerationPassReports(callID: stallWatchId)
        let stallWatchdog = helperTasks.start { await self.watchGenerationForStalls(id: stallWatchId) }
        defer {
            closeGenerationPassReports(callID: stallWatchId, reader: passReports)
            stallWatchdog.cancel()
            endGenerationStallWatch(id: stallWatchId)
        }
        // The tool-result append boundary of this model call: each tool result
        // the model reads next goes through it (see ``noteToolResult(_:)``),
        // and then the check of the delegate hint
        // (``noteDelegationHintDue()``).
        // The no-op check and then the repetition check run before each tool
        // body of the call (see ``checkToolCallForNoOp(toolName:arguments:)``
        // and ``checkToolCallForRepetition(_:)``). The tool hooks of the
        // session run around each tool body of the call, and each tool body
        // reads the hook session of this session (see ``makeToolCallHooks()``).
        let submission = Self.submission(
            of: body, composedPrompt: composedPrompt, mark: modelCallMark,
            boundary: ToolResultAppendBoundary {
                await self.noteToolResult($0)
                await self.noteDelegationHintDue()
            },
            checks: ModelCallToolChecks(
                noOp: ToolCallNoOpCheck { try await self.checkToolCallForNoOp(toolName: $0, arguments: $1) },
                repetition: ToolCallRepetitionCheck { try await self.checkToolCallForRepetition($0) },
                hooks: makeToolCallHooks()),
            context: ambientToolContext,
            serviceContext: submissionServiceContext,
            origin: origin,
            callerWork: openAnswerCallerWork,
            session: self)
        let observer = generationPassObserver
        let metrics = sessionMetrics
        let modelCall = Task {
            try await Self.run(
                submission, on: target, reportingTo: observer, metrics: metrics,
                onStart: { await OriginContext.$current.withValue(origin) { await self.submissionDidStart() } })
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
    /// of each tool call stays a child of the span of its submission. The
    /// ``SessionOwnWork`` of the session of `context` is one more: each tool
    /// body of the call, and each run body that a tool body starts, is the
    /// own work of that session, so ``close()`` from it does not wait for
    /// itself. It is also the own work that the mail of the answer carries
    /// from its senders (`callerWork`, task ^hrkxav5), so a close of the
    /// session of a sender that waits for this answer does not wait for
    /// itself either. The session itself is one more
    /// (``SubagentQuestionHost/session``): a tool body or a run body that
    /// drives a subagent reads it through ``SubagentQuestionTarget/current``.
    ///
    /// - Parameters:
    ///   - body: The model work: one whole SDK call.
    ///   - composedPrompt: The composed prompt of the attempt.
    ///   - mark: The mark of the model call.
    ///   - boundary: The tool-result append boundary of the model call.
    ///   - checks: The checks before each tool body of the model call.
    ///   - context: The ambient ``ToolContext`` of the model call.
    ///   - serviceContext: The tracing context of the submission
    ///     (``submissionServiceContext``), or `nil`.
    ///   - origin: The origin of the work that makes the call
    ///     (``OriginContext/current``).
    ///   - callerWork: The own work that the mail of the open answer carries
    ///     from its senders (``openAnswerCallerWork``).
    ///   - session: The session that submits the call.
    /// - Returns: The submission.
    private static func submission(
        of body: @escaping @Sendable (String) async throws -> String,
        composedPrompt: String,
        mark: ModelCallMark,
        boundary: ToolResultAppendBoundary,
        checks: ModelCallToolChecks,
        context: ToolContext,
        serviceContext: ServiceContext?,
        origin: Origin,
        callerWork: SessionOwnWork,
        session: RoutedSessionActor
    ) -> @Sendable () async throws -> String {
        {
            try await OriginContext.$current.withValue(origin) {
                try await ServiceContext.$current.withValue(serviceContext) {
                    try await ModelCallMark.$current.withValue(mark) {
                        try await ToolResultAppendBoundary.$current.withValue(boundary) {
                            try await checks.bound {
                                try await ToolContext.$current.withValue(context) {
                                    try await SessionOwnWork.run(as: context.sessionID, carrying: callerWork) {
                                        try await SubagentQuestionHost.$session.withValue(session) {
                                            try await body(composedPrompt)
                                        }
                                    }
                                }
                            }
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
    /// At the start of a queue item, the item also sets the gauge of the
    /// submissions that wait behind it in the queue of its model
    /// (``RouterMetrics/recordGenerationQueueWaiting(_:model:)``). The item
    /// runs on the worker task of the queue, and not on the pump, so the read
    /// of the count adds no suspension point to the pump.
    ///
    /// - Parameters:
    ///   - submission: The submission of one model call.
    ///   - target: The queue of the model and the model, or `nil`.
    ///   - observer: The observer of this session's model calls.
    ///   - metrics: The metrics recorder of this session.
    ///   - onStart: The closure that reports the start of the submission. It
    ///     runs at the start of the queue item, or before the direct call.
    /// - Returns: What `submission` returns.
    /// - Throws: What the queue or `submission` throws.
    private static func run(
        _ submission: @escaping @Sendable () async throws -> String,
        on target: SubmissionTarget?,
        reportingTo observer: GenerationPassObserver,
        metrics: RouterMetrics,
        onStart: @escaping @Sendable () async -> Void
    ) async throws -> String {
        guard let target else {
            await onStart()
            return try await submission()
        }
        return try await target.queue.submit(onQueued: { observer.submissionQueued() }) {
            observer.submissionStarted()
            metrics.recordGenerationQueueWaiting(await target.queue.waitingCount, model: target.model)
            await onStart()
            return try await submission()
        }
    }

    /// Whether a cancellation is outstanding against the work the pump runs,
    /// by any route: `Task.isCancelled` of the task that reads it, or
    /// ``cancelRequestedWorkId`` set for that work by
    /// ``requestCancelOfRunningWork()`` (``RoutedSession/cancelAll()``,
    /// ``RoutedSession/close()``). This is the one read site of
    /// ``cancelRequestedWorkId``, so the routes cannot diverge. Every cancel
    /// decision keys on this predicate, never on the type of a
    /// `CancellationError`. Read after each `await`; do not cache.
    ///
    /// A cancel of one mail never stops the work (``RoutedSession/cancel(_:)``):
    /// it acts only on queued mail.
    var isWorkCancelled: Bool {
        if Task.isCancelled { return true }
        guard let workId = pumpWork?.id else { return false }
        return cancelRequestedWorkId == workId
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
    /// the tokenizer of its model. `retryPrompt` is the render of the mail
    /// that the retry carries, then the text of the session. Mail that
    /// joins the retry when it starts is not in it.
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
            promptTokens: tokenCounter.count(retryPrompt),
            configuredTargetTokens: budget.targetTokens)
    }
}
