import FoundationModels
import FoundationModelsExtras
import Tracing

/// What one submission runs, as the options of its batch ask: the grammar
/// in force and the model work.
struct SubmissionWork {
    /// The grammar that constrains the response, or `nil`.
    let grammar: Grammar?

    /// The model work: one whole SDK call over the composed prompt.
    let body: @Sendable (String) async throws -> String
}

/// ``RoutedSessionActor``'s generation surface: the thin helpers on top of
/// ``RoutedSession/mail(_:)`` (`mailbox.md`, section 4, decision 2), the
/// waits for a terminal event, the output of the session, and the model
/// work of a submission.
///
/// Each helper sends one mail and reads the output of that mail
/// (`generation-queue.md`, section 5.4). The pump of the session submits the
/// mail; the helper itself submits nothing.
extension RoutedSessionActor {
    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Sends one user message in reply mode and reads its output to its
    /// terminal event. The answer is the final reply of the submission that
    /// carried the message, and of each continuation of it. A background run
    /// that the submission started does not hold the answer: its terminal
    /// comes back as run mail, and the pump delivers it in a later
    /// submission.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model, bounded by the pass token limit of
    ///     the session (``RepetitionDetection/passTokenLimit``), as the ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: The error of a failed answer, `CancellationError` when the
    ///   message was cancelled or the answer was cancelled, the refusal of
    ///   ``mail(_:)``, or ``GenerationQueueError/waitInsideOpenSubmission(model:)``
    ///   when this call comes from an in-band tool body of an open submission
    ///   on this session or on the queue of its model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let events = streamEvents(of: Self.userMessage(prompt, maxTokens: maxTokens, mode: .reply))
        return try await SessionAnswer.awaitEnd(of: events, observing: nil).reply
    }

    /// See ``RoutedSession/streamEvents(to:maxTokens:)``. Sends one user
    /// message in stream mode, and gives the events of that message to its
    /// terminal event.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model, bounded by the pass token limit of
    ///     the session (``RepetitionDetection/passTokenLimit``), as the ceiling.
    /// - Returns: A stream of session events, finishing after the terminal
    ///   event of the message, or throwing the error of a failed answer
    ///   after its ``SessionEvent/answerFailed(_:)``.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error> {
        streamEvents(of: Self.userMessage(prompt, maxTokens: maxTokens, mode: .stream))
    }

    /// Streams a text response to a prompt as it is produced, recording the
    /// call. Sends one user message in stream mode, and gives the text of
    /// each ``SessionEvent/textDelta(_:)`` of that message. A guided session
    /// never streams, so its stream gives the reply of the terminal event as
    /// one element.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model, bounded by the pass token limit of
    ///     the session (``RepetitionDetection/passTokenLimit``), as the ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let events = streamEvents(to: prompt, maxTokens: maxTokens)
        let isGuided = grammar != nil
        return Self.wrapAsyncStream { continuation in
            for try await event in events {
                if let text = Self.responseText(of: event, isGuided: isGuided) {
                    continuation.yield(text)
                }
            }
        }
    }

    /// The text that ``streamResponse(to:maxTokens:)`` gives for `event`:
    /// the text of a ``SessionEvent/textDelta(_:)``, or, for a guided
    /// session, the reply of ``SessionEvent/answered(_:)``.
    ///
    /// - Parameters:
    ///   - event: One event of the message.
    ///   - isGuided: Whether the session has a grammar.
    /// - Returns: The text, or `nil` for an event that gives no text.
    private static func responseText(of event: SessionEvent, isGuided: Bool) -> String? {
        switch event {
        case .textDelta(let text):
            return text
        case .answered(let answer) where isGuided:
            return answer.reply
        default:
            return nil
        }
    }

    /// See ``RoutedSession/awaitTerminal(of:)-(MailID)``. Waits for the
    /// terminal event of the mail `id`, and returns at once when it already
    /// came (``SessionOutputHub``). A cancel of the calling task cancels the
    /// mail while it is queued (``cancel(_:)``), and ends the wait. It never
    /// stops an answer that runs.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: ``SessionEvent/answered(_:)``, ``SessionEvent/answerFailed(_:)``,
    ///   ``SessionEvent/cancelled(_:)`` or ``SessionEvent/lost(_:)``.
    /// - Throws: `CancellationError` when the calling task is cancelled first,
    ///   ``MailRefusal/closed`` when the session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func awaitTerminal(of id: MailID) async throws -> SessionEvent {
        try await awaitMailTerminal(of: id).event
    }

    /// See ``RoutedSession/awaitAnswer(of:)``. Waits for the terminal event
    /// of the mail `id`, as ``awaitTerminal(of:)-(MailID)`` does, and gives
    /// its answer or throws its error (``SessionOutputHub/Terminal/answer()``).
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The ``SessionAnswer`` of the answer that delivered the mail.
    /// - Throws: The original error of a failed answer, `CancellationError`
    ///   for a cancelled or lost mail or a cancelled calling task,
    ///   ``MailRefusal/closed`` when the session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func awaitAnswer(of id: MailID) async throws -> SessionAnswer {
        try await awaitMailTerminal(of: id).answer()
    }

    /// The wait of ``awaitTerminal(of:)-(MailID)`` and ``awaitAnswer(of:)``:
    /// the terminal event of the mail `id` and the error of a failed answer.
    /// A cancel of the calling task cancels the mail while it is queued
    /// (``cancel(_:)``), and ends the wait.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The terminal event and its error, from the ledger of
    ///   ``outputHub``.
    /// - Throws: `CancellationError` when the calling task is cancelled first,
    ///   ``MailRefusal/closed`` when the session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    private func awaitMailTerminal(of id: MailID) async throws -> SessionOutputHub.Terminal {
        try refuseWaitInsideOpenSubmission()
        return try await withTaskCancellationHandler {
            try await outputHub.awaitTerminal(of: .mail(id))
        } onCancel: {
            cancel(id)
        }
    }

    /// See ``RoutedSession/awaitTerminal(of:)-(SignalID)``. Waits for the
    /// terminal event of the signal `id`: ``SessionEvent/signalDone(_:)``, or
    /// for a compaction ``SessionEvent/compaction(_:)`` or
    /// ``SessionEvent/compactionFailed(_:)`` whose id is the signal id.
    /// Returns at once when it already came.
    ///
    /// - Parameter id: The id of the signal.
    /// - Returns: The terminal event of the signal.
    /// - Throws: `CancellationError` when the calling task is cancelled first,
    ///   ``MailRefusal/closed`` when the session closes first, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func awaitTerminal(of id: SignalID) async throws -> SessionEvent {
        try refuseWaitInsideOpenSubmission()
        return try await outputHub.awaitTerminal(of: .signal(id.description)).event
    }

    /// A user message from the user of the session.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - maxTokens: The token ceiling, or `nil`.
    ///   - mode: Reply or stream.
    /// - Returns: The mail, with a new id.
    static func userMessage(_ prompt: String, maxTokens: Int?, mode: UserMessageOptions.Mode) -> Mail {
        Mail(sender: .user, body: .userMessage(prompt: prompt, options: UserMessageOptions(maxTokens: maxTokens, mode: mode)))
    }

    /// Sends `mail` and gives its events to its terminal event: the helper
    /// that ``respond(to:maxTokens:)`` and the stream methods are.
    ///
    /// The refusal of a wait that could never end comes first, on the task
    /// of the stream (``refuseWaitInsideOpenSubmission()``). A cancel of the
    /// reader cancels the mail while it is queued (``cancel(_:)``); it never
    /// stops an answer that runs.
    ///
    /// - Parameter mail: The mail to send.
    /// - Returns: The events of the mail. The stream finishes after
    ///   ``SessionEvent/answered(_:)``. It throws the error of a failed answer
    ///   after ``SessionEvent/answerFailed(_:)``, and `CancellationError`
    ///   after ``SessionEvent/cancelled(_:)`` or ``SessionEvent/lost(_:)``, or
    ///   when the reader stops before the terminal event.
    private func streamEvents(of mail: Mail) -> AsyncThrowingStream<SessionEvent, Error> {
        Self.wrapAsyncStream { continuation in
            try await self.refuseWaitInsideOpenSubmission()
            // A reader that stopped before the send sends no mail, so no
            // pump can take the mail before the cancel below removes it.
            try Task.checkCancellation()
            let subscription = try self.mail(mail)
            await withTaskCancellationHandler {
                for await output in subscription {
                    continuation.yield(output.event)
                }
            } onCancel: {
                self.cancel(mail.id)
            }
            // A reader that stopped before the terminal event finds no
            // terminal event in the ledger.
            guard let terminal = self.outputHub.terminal(for: .mail(mail.id)) else { throw CancellationError() }
            _ = try terminal.answer()
        }
    }

    /// Refuses a wait for an answer of this session that could never end
    /// (`generation-queue.md`, section 5.5, rule 2): a wait from an in-band
    /// tool body of an open submission of this session, or of an open
    /// submission on the queue of its model. That submission waits for the
    /// tool body, and the answer could come only after it.
    ///
    /// A background body has a closed mark
    /// (``ModelCallMark/withBackgroundRunMark(_:)``), so it is never refused:
    /// its mail waits for a later submission.
    ///
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func refuseWaitInsideOpenSubmission() throws {
        if ModelCallMark.current?.isOpenModelCall(of: id) == true {
            throw GenerationQueueError.waitInsideOpenSubmission(model: model)
        }
        try backend.generationQueue?.refuseWaitInsideOpenSubmission()
    }

    /// What one submission runs for the options of its batch.
    ///
    /// A reply runs the respond call of ``backend``, under the grammar of the
    /// session. A stream runs the stream call, with no grammar, and sends
    /// each fragment to the output of the session as
    /// ``SessionEvent/textReset`` and ``SessionEvent/textDelta(_:)``. A
    /// guided session never streams (``SubmissionOptions/init(for:isGuided:)``).
    ///
    /// - Parameters:
    ///   - isStream: Whether the submission gives its output as a stream.
    ///   - ceiling: The token ceiling of the submission.
    /// - Returns: The work of the submission.
    func submissionWork(isStream: Bool, responseTokenCeiling ceiling: ResponseTokenCeiling) -> SubmissionWork {
        guard isStream else {
            return SubmissionWork(grammar: grammar, body: respondBody(grammar: grammar, responseTokenCeiling: ceiling.resolved))
        }
        return SubmissionWork(grammar: nil) { composedPrompt in
            try await self.streamGeneratingBody(composedPrompt: composedPrompt, responseTokenCeiling: ceiling.resolved)
        }
    }

    /// Wraps `body` in an `AsyncThrowingStream`, running it inside a
    /// cancellable `Task` that finishes the stream when `body` returns or
    /// throws.
    ///
    /// - Parameter body: The streaming work, given the stream's continuation.
    /// - Returns: The wrapped stream.
    private static func wrapAsyncStream<Element>(
        _ body: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Runs `backend.streamResponseFragments(to:maxTokens:)`, sends the
    /// events of each fragment to the output of the session
    /// (``sessionEvents(for:)``), and accumulates the text. A fragment marked
    /// ``ResponseFragment/restartsResponse`` replaces the accumulated text.
    ///
    /// - Parameters:
    ///   - composedPrompt: The prompt, already composed with the run mail.
    ///   - maxTokens: The ceiling to give the backend, as
    ///     ``ResponseTokenCeiling/resolved`` gives it.
    /// - Returns: The accumulated response text.
    /// - Throws: Any error thrown by the model, or `CancellationError` when
    ///   the model call was cancelled during the stream.
    func streamGeneratingBody(composedPrompt: String, responseTokenCeiling maxTokens: Int?) async throws -> String {
        var response = ""
        // The stall watch of this submission counts real increments (task ^z6xcmnh):
        // declared here so a streaming submission that has produced nothing yet is
        // still reported as one the session can see fragments on, and noted per
        // append below so the report is measured from the last one. A fragment
        // with no text still reports an append: a tool call, a tool result, or
        // a reasoning entry (task ^4799jxg).
        observeGenerationFragments()
        for try await fragment in backend.streamResponseFragments(
            to: composedPrompt, maxTokens: maxTokens)
        {
            noteGenerationProgress(fragment.progress)
            // The text events go to the output of the session
            // (`generation-queue.md`, section 5.6), where the subscription of
            // the mail of the answer reads them.
            for event in Self.sessionEvents(for: fragment) {
                emitSessionScopedEvent(event)
            }
            response = fragment.restartsResponse ? fragment.text : response + fragment.text
        }
        // An `AsyncThrowingStream` whose consumer is cancelled *ends* — its
        // `next()` returns `nil` rather than throwing — so a cancelled streaming
        // submission would otherwise fall out of that loop holding a
        // half-produced `response` and be reported as a submission that simply
        // finished, indexed recording and all. It did not finish: it was cut
        // short (see ``RoutedSession/cancelAll()``). Raising it here
        // routes a truncated stream into the same failed-submission handling
        // every other mid-generation failure takes, so the caller can tell the
        // two apart.
        // Whatever was already sent stays sent — a cancelled stream is
        // truncated, never retracted.
        try Task.checkCancellation()
        return response
    }

    /// See ``RoutedSession/streamSessionEvents()``. Makes one feed of
    /// ``outputHub`` with an unbounded buffer.
    func streamSessionEvents() -> AsyncStream<SessionOutput> {
        outputHub.makeFeed()
    }

    /// Sends one event to the output of the session (``outputHub``), with the
    /// origin of the work that sends it (``OriginContext/current``).
    ///
    /// When the event is the terminal event of a mail and the output sent it,
    /// the transcript records the terminal event of each mail that it ends
    /// (``recordMail(_:)``). This is the one place where the output sends a
    /// terminal event, so each terminal event gets one record, and each mail
    /// that ends with ``SessionEvent/cancelled(_:)`` adds one to the counter
    /// of cancelled mail (``RouterMetrics/recordCancelledMail(_:)``).
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - error: The error that ended a failed answer, when `event` is its
    ///     ``SessionEvent/answerFailed(_:)``, or `nil`.
    ///   - audience: The mail of the answer whose work sends `event`, or no
    ///     mail (the default). See ``SessionOutputHub/emit(_:failure:audience:)``.
    nonisolated func emitSessionScopedEvent(
        _ event: SessionEvent, failure error: (any Error)? = nil, audience: Set<MailID> = []
    ) {
        let ended = outputHub.emit(
            SessionOutput(origin: OriginContext.current, event: event), failure: error, audience: audience)
        let records = Self.terminalRecords(of: event, ending: ended)
        recordMail(records)
        sessionMetrics.recordCancelledMail(records.filter(\.isCancellation).count)
    }

    /// Sends the terminal event ``SessionEvent/cancelled(_:)`` of each mail
    /// that left the queue before the pump took it. A signal that removed
    /// the mail (``Origin/signal(_:)``) gives the event its own origin. For
    /// each other removal, the origin of the event is the mail itself.
    ///
    /// - Parameter mailIDs: The ids of the mail, in queue order.
    nonisolated func emitCancelled(_ mailIDs: [MailID]) {
        let signal: Origin? = if case .signal = OriginContext.current { OriginContext.current } else { nil }
        for mailID in mailIDs {
            OriginContext.$current.withValue(signal ?? .mail([mailID])) {
                emitSessionScopedEvent(.cancelled(mailID))
            }
        }
    }

    /// Finishes every live ``streamSessionEvents()`` feed, so a consumer ends
    /// when the session does. A second ``close()`` has nothing left to
    /// finish.
    func finishSessionEventSubscriptions() {
        outputHub.finishFeeds()
    }

    /// The events one streamed ``ResponseFragment`` implies, in yield order.
    /// A restarting fragment yields ``SessionEvent/textReset`` first. Non-empty
    /// text follows as ``SessionEvent/textDelta(_:)``.
    /// ``streamGeneratingBody(composedPrompt:responseTokenCeiling:)`` gives
    /// these events to ``emitSessionScopedEvent(_:failure:audience:)`` for each
    /// fragment.
    ///
    /// - Parameter fragment: The fragment just received from the backend.
    /// - Returns: The events to yield for it, in order.
    static func sessionEvents(for fragment: ResponseFragment) -> [SessionEvent] {
        let reset: [SessionEvent] = fragment.restartsResponse ? [.textReset] : []
        return fragment.text.isEmpty ? reset : reset + [.textDelta(fragment.text)]
    }
}
