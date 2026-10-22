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
/// session. ``beginSubmission(cause:mailIds:)`` opens it when the attempt
/// starts, ``submissionDidStart()`` reports its start when its SDK call
/// starts, and ``endSubmission(usage:finishReason:onEvent:)``
/// ends it where the attempt is recorded. A summarizer call of a compaction
/// opens no submission and sends no event of its own.
extension RoutedSessionActor {
    /// Opens the next submission of the running answer: it takes the next
    /// ``SubmissionID`` and opens the span of the submission, a child of the
    /// tracing context of the caller. The span links to the sender of each
    /// mail of `mailIds` that has a sender context (``openAnswerMailSenders``).
    ///
    /// A submission can wait a long time in its model call, so it also writes
    /// one "enter" log record through ``sessionLogger(_:)`` when its span
    /// opens (``RouterTelemetry/EnterRecord``). This method opens the span and
    /// ``endSubmission(usage:finishReason:onEvent:)`` ends it,
    /// so `TracedCall.run` of FoundationModelsExtras, which ends its span when
    /// its body returns, does not fit: this method writes the same record.
    /// The log call is synchronous, so it adds no suspension point to the
    /// pump.
    ///
    /// - Parameters:
    ///   - cause: Why the session makes the submission.
    ///   - mailIds: The ids of the mail the submission delivers.
    func beginSubmission(cause: SubmissionStart.Cause, mailIds: [MailID]) {
        lastSubmissionNumber += 1
        let start = SubmissionStart(
            submissionId: SubmissionID(lastSubmissionNumber), mailIds: mailIds, cause: cause)
        let spanTracer = RouterTelemetry.tracer(explicit: tracer)
        let span = spanTracer.startSpan(
            RouterTelemetry.SpanName.submission, context: ServiceContext.current ?? .topLevel, ofKind: .client)
        describeSession(on: span)
        span.attributes[RouterTelemetry.AttributeKey.submissionId] = start.submissionId.description
        span.attributes[RouterTelemetry.AttributeKey.submissionCause] = cause.rawValue
        span.attributes[RouterTelemetry.AttributeKey.submissionMailIds] = mailIds.map(\.description)
        // One link to the span of the sender of each mail that the
        // submission delivers (task ^yx6931z). Run mail can come from
        // another trace, for example the session of a subagent.
        for sender in mailIds.compactMap({ openAnswerMailSenders[$0] }) {
            span.addLink(SpanLink(context: sender, attributes: [:]))
        }
        RouterTelemetry.EnterRecord.write(
            for: span, named: RouterTelemetry.SpanName.submission, tracer: spanTracer, to: sessionLogger(.enter))
        runningSubmission = RunningSubmission(start: start, span: span)
        // The start of each submission is the activity of the session that
        // its record lists: `updatedAt` moves, and the first submission sets
        // `firstActivityAt`, so a listing can leave out a session that never
        // had a prompt.
        recordSubmissionStart()
    }

    /// Writes the attributes that name this session on `span`: the router
    /// id, the session id and the model reference.
    ///
    /// The submission span and the fork span of a session carry these three
    /// attributes, so one method writes them for both.
    ///
    /// - Parameter span: The span of work that runs on this session.
    func describeSession(on span: any Span) {
        span.attributes[RouterTelemetry.AttributeKey.routerId] = routerId.description
        span.attributes[RouterTelemetry.AttributeKey.sessionId] = id.description
        span.attributes[RouterTelemetry.AttributeKey.modelRef] = model.stringValue
    }

    /// What the first submission of an answer delivers, and why the session
    /// makes it: ``SubmissionStart/Cause/message`` when the batch holds
    /// user-type mail, and ``SubmissionStart/Cause/mail`` when only run mail
    /// starts it.
    ///
    /// - Returns: The cause and the ids of all mail of the batch.
    func firstSubmissionDelivery() -> (cause: SubmissionStart.Cause, mailIds: [MailID]) {
        (openAnswerDeliveredUserMail ? .message : .mail, deliveredMailIds)
    }

    /// The ids of the mail the running answer delivered so far, in delivery
    /// order, user-type mail and run mail. Run mail that a failed submission
    /// gave back to the queue is not in it. Empty when no answer runs.
    var deliveredMailIds: [MailID] {
        openAnswerMail.all
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
    /// for the same submission, and a call with no open submission, send
    /// nothing.
    func submissionDidStart() {
        drainGenerationPassPhases()
        guard var running = runningSubmission, !running.hasStarted else { return }
        running.hasStarted = true
        runningSubmission = running
        deliverLive(.submissionStarted(running.start))
    }

    /// Records the failure of `error` on the span of the running submission,
    /// the error that ended its attempt.
    ///
    /// The span gets the error status and the type name of the error
    /// (``RouterTelemetry/recordFailure(of:on:)``). It does not get the error
    /// itself, because the description of an error can hold the caller's
    /// content, for example the arguments of a rejected tool call.
    ///
    /// - Parameter error: The error of the attempt.
    func recordSubmissionError(_ error: any Error) {
        guard let span = runningSubmission?.span else { return }
        RouterTelemetry.recordFailure(of: error, on: span)
    }

    /// Ends the running submission: it sends
    /// ``SessionEvent/submissionEnded(_:)`` and ends the span of the
    /// submission. With no open submission (a proactive compaction that
    /// failed before the first submission) it does nothing.
    ///
    /// - Parameters:
    ///   - usage: The measured usage of the submission, or `nil` when the
    ///     backend reports none.
    ///     The span carries its fed and generated tokens.
    ///   - finishReason: Why the submission stopped.
    ///   - onEvent: The event sink of the answer, or `nil`.
    func endSubmission(
        usage: TokenUsage?,
        finishReason: FinishReason,
        onEvent: ((SessionEvent) -> Void)?
    ) {
        guard let running = runningSubmission else { return }
        runningSubmission = nil
        // A compaction that waits to apply its snapshot wakes.
        submissionCloses.signal()
        // The usage of the submission, summed over its generation calls, a
        // call that a watch stop cancelled with them. The counted size of
        // the render is not: after a watch stop it is the render of the next
        // pass, with no output (task ^e5kyhwb).
        if let usage {
            running.span.attributes[RouterTelemetry.AttributeKey.tokensIn] = usage.tokensIn
            running.span.attributes[RouterTelemetry.AttributeKey.tokensOut] = usage.tokensOut
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
        let mailIds = deliveredMailIds
        switch result {
        case .success(let reply):
            return .answered(answerReducer.answer(reply: reply, mailIds: mailIds))
        case .failure(let error):
            let reason: AnswerFailure.Reason = isWorkCancelled ? .cancelled : .error(String(describing: error))
            return .answerFailed(AnswerFailure(mailIds: mailIds, reason: reason))
        }
    }

    /// The error that the helpers on top of the core throw for the end of
    /// the running answer: `nil` for an answer, `CancellationError` when a
    /// cancel is outstanding against the work (``isWorkCancelled``), and the
    /// error of `result` otherwise. The decision keys on the same predicate
    /// as ``answerEndEvent(for:)``.
    ///
    /// - Parameter result: The final reply of the chain, or its error.
    /// - Returns: The error of a failed answer, or `nil`.
    func answerEndError(for result: Result<String, any Error>) -> (any Error)? {
        guard case .failure(let error) = result else { return nil }
        return isWorkCancelled ? CancellationError() : error
    }

    /// Sends the end of the running answer to the output of the session:
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``,
    /// the terminal event of each mail that the answer delivered. The ledger
    /// of the output keeps the error of a failed answer next to its event
    /// (``answerEndError(for:)``).
    ///
    /// The ids leave ``openAnswerMail`` directly after the event, so a caller
    /// that got the terminal event can use the same id again. They leave
    /// after the event and not before it: a mail subscription of a new mail
    /// with the same id must not get the end of this answer.
    ///
    /// - Parameter result: The final reply of the chain, or its error.
    func emitAnswerEnd(for result: Result<String, any Error>) {
        let end = answerEndEvent(for: result)
        answerReducer.apply(end)
        emitSessionScopedEvent(end, failure: answerEndError(for: result))
        openAnswerMail.removeAll()
    }
}
