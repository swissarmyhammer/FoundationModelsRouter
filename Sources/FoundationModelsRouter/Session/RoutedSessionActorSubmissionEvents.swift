import Tracing

/// One submission of the running answer that the session opened and did not
/// end yet (`generation-queue.md`, section 5.6).
struct RunningSubmission {
    /// The start record of the submission.
    let start: SubmissionStart

    /// The span of the submission. It ends when the submission ends.
    let span: any Span

    /// Whether the session sent ``SessionEvent/submissionStarted(_:)`` for
    /// the submission.
    var hasStarted = false
}

/// ``RoutedSessionActor``'s events of a submission and of an answer, and the
/// span of each submission (task ^x7cxsg3, `generation-queue.md`, section
/// 5.6).
///
/// A submission is one attempt of the chain that answers the messages of the
/// session. ``beginSubmission(cause:messageIds:)`` opens it when the attempt
/// starts, ``submissionDidStart()`` reports its start when its SDK call
/// starts, and ``endSubmission(usage:finishReason:measuredRender:onEvent:)``
/// ends it where the attempt is recorded. A summarizer call of a compaction
/// runs between two submissions, so it opens none and sends no event of its
/// own.
extension RoutedSessionActor {
    /// Opens the next submission of the running answer: it takes the next
    /// ``SubmissionID`` and opens the span of the submission, a child of the
    /// tracing context of the caller.
    ///
    /// - Parameters:
    ///   - cause: Why the session makes the submission.
    ///   - messageIds: The caller messages the submission delivers.
    func beginSubmission(cause: SubmissionStart.Cause, messageIds: [MessageID]) {
        lastSubmissionNumber += 1
        let start = SubmissionStart(
            submissionId: SubmissionID(lastSubmissionNumber), messageIds: messageIds, cause: cause)
        let span = RouterTracing.tracer(explicit: tracer).startSpan(
            RouterTracing.SpanName.submission, context: ServiceContext.current ?? .topLevel, ofKind: .client)
        span.attributes[RouterTracing.AttributeKey.routerId] = routerId.description
        span.attributes[RouterTracing.AttributeKey.sessionId] = id.description
        span.attributes[RouterTracing.AttributeKey.modelRef] = model.stringValue
        span.attributes[RouterTracing.AttributeKey.submissionId] = start.submissionId.description
        span.attributes[RouterTracing.AttributeKey.submissionCause] = cause.rawValue
        runningSubmission = RunningSubmission(start: start, span: span)
    }

    /// What the first submission of an answer delivers, and why the session
    /// makes it: the caller messages of the answer, or mail alone.
    ///
    /// - Returns: The cause and the ids of the caller messages.
    func firstSubmissionDelivery() -> (cause: SubmissionStart.Cause, messageIds: [MessageID]) {
        let messageIds = (deliveredMessages ?? []).map(\.id)
        return (messageIds.isEmpty ? .mail : .message, messageIds)
    }

    /// The tracing context of the running submission, or the context of the
    /// task that reads it when no submission is open. The SDK call of a
    /// submission binds it, so the span of each tool call is a child of the
    /// span of its submission.
    var submissionServiceContext: ServiceContext? {
        runningSubmission?.span.context ?? ServiceContext.current
    }

    /// Reports that the SDK call of the running submission started: the
    /// worker of its queue started it, or, with no queue, the call started.
    ///
    /// The reported phases apply first, so a ``SessionEvent/submissionQueued(_:)``
    /// of the same submission always comes before its start. A second call
    /// for the same submission, and a call with no open submission (a
    /// summarizer call of a compaction), send nothing.
    func submissionDidStart() {
        drainGenerationPassPhases()
        guard var running = runningSubmission, !running.hasStarted else { return }
        running.hasStarted = true
        runningSubmission = running
        deliverLive(.submissionStarted(running.start))
    }

    /// Records `error` on the span of the running submission, the error that
    /// ended its attempt.
    ///
    /// - Parameter error: The error of the attempt.
    func recordSubmissionError(_ error: any Error) {
        runningSubmission?.span.recordError(error)
    }

    /// Ends the running submission: it sends
    /// ``SessionEvent/submissionEnded(_:)`` and ends the span of the
    /// submission. With no open submission (a proactive compaction that
    /// failed before the first submission) it does nothing.
    ///
    /// - Parameters:
    ///   - usage: The measured usage of the submission, or `nil` when the
    ///     backend reports none.
    ///   - finishReason: Why the submission stopped.
    ///   - measuredRender: The fed and generated tokens of the newest
    ///     generation call, when the submission measured the render; the span
    ///     carries them.
    ///   - onEvent: The event sink of the answer, or `nil`.
    func endSubmission(
        usage: TokenUsage?,
        finishReason: FinishReason,
        measuredRender: (input: Int, output: Int)?,
        onEvent: ((SessionEvent) -> Void)?
    ) {
        guard let running = runningSubmission else { return }
        runningSubmission = nil
        if let measuredRender {
            running.span.attributes[RouterTracing.AttributeKey.tokensIn] = measuredRender.input
            running.span.attributes[RouterTracing.AttributeKey.tokensOut] = measuredRender.output
        }
        onEvent?(
            .submissionEnded(
                SubmissionEnd(submissionId: running.start.submissionId, usage: usage, finishReason: finishReason)))
        running.span.end()
    }

    /// The event of the end of the running answer: its final answer, or the
    /// failure that ended it.
    ///
    /// The reason of a failure is ``AnswerFailure/Reason/cancelled`` when a
    /// cancel is outstanding against the work (``isWorkCancelled``), and the
    /// description of `result`'s error otherwise. The decision keys on the
    /// predicate, never on the type of a `CancellationError`.
    ///
    /// - Parameter result: The final reply of the chain, or its error.
    /// - Returns: ``SessionEvent/answered(_:)`` or
    ///   ``SessionEvent/answerFailed(_:)``.
    func answerEndEvent(for result: Result<String, any Error>) -> SessionEvent {
        let messageIds = (deliveredMessages ?? []).map(\.id)
        switch result {
        case .success(let reply):
            return .answered(answerReducer.answer(reply: reply, messageIds: messageIds))
        case .failure(let error):
            let reason: AnswerFailure.Reason = isWorkCancelled ? .cancelled : .error(String(describing: error))
            return .answerFailed(AnswerFailure(messageIds: messageIds, reason: reason))
        }
    }
}
