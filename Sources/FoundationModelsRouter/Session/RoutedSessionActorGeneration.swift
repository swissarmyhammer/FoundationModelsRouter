import FoundationModels
import Tracing

/// What one submission runs, as the reader of its first message asks: the
/// grammar in force, the model work, and the event sink of the answer.
struct SubmissionWork {
    /// The grammar that constrains the response, or `nil`.
    let grammar: Grammar?

    /// The event sink of the answer, or `nil` when no caller reads events.
    let onEvent: (@Sendable (SessionEvent) -> Void)?

    /// The model work: one whole SDK call over the composed prompt.
    let body: @Sendable (String) async throws -> String
}

/// ``RoutedSessionActor``'s generation surface: the response, chunk-stream, and
/// event-stream helpers a caller drives, plus the session-scoped event
/// subscriptions a host watches a whole session through.
///
/// Each helper sends one message and waits for its answer
/// (`generation-queue.md`, section 5.4). The pump of the session submits the
/// message; the helper itself submits nothing.
extension RoutedSessionActor {
    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Sends one message and waits for its answer. The answer is the final
    /// reply of the submission that carried the message, and of each
    /// continuation of it. A background run that the submission started does
    /// not hold the answer: its terminal comes back as mail, and the pump
    /// delivers it in a later submission.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model as the ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model, `CancellationError` when the
    ///   message was cancelled, or
    ///   ``GenerationQueueError/waitInsideOpenSubmission(model:)`` when this
    ///   call comes from an in-band tool body of an open submission on this
    ///   session or on the queue of its model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await sendAndAwaitAnswer(text: prompt, requestedMaxTokens: maxTokens, reader: .reply, entryPoint: .respond)
    }

    /// Sends one caller message and waits for its answer.
    ///
    /// The refusal of a wait that could never end comes first, on the task
    /// of the caller (``refuseWaitInsideOpenSubmission()``). The message then
    /// waits in ``outbox``, and the pump takes it for the next submission
    /// that can carry it.
    ///
    /// - Parameters:
    ///   - text: The prompt text of the message.
    ///   - requestedMaxTokens: The token ceiling the caller named, or `nil`.
    ///   - reader: Who reads the output of the submission.
    ///   - entryPoint: The surface the caller used.
    /// - Returns: The final reply of the answer that carried the message.
    /// - Throws: What the answer throws, `CancellationError` when the message
    ///   was cancelled, or the refusal.
    private func sendAndAwaitAnswer(
        text: String, requestedMaxTokens: Int?, reader: MessageReader, entryPoint: RouterTracing.TurnEntryPoint
    ) async throws -> String {
        try refuseWaitInsideOpenSubmission()
        await attachOutboxJournalIfNeeded()
        let message = SessionMessage(
            id: PromptID(), text: text, requestedMaxTokens: requestedMaxTokens, reader: reader,
            entryPoint: entryPoint, serviceContext: ServiceContext.current, answer: PumpAnswer())
        await outbox.add(message: message)
        wakePump()
        return try await awaitAnswer(of: message)
    }

    /// Waits for the answer of `message`. A cancel of the caller marks the
    /// message and asks the session to withdraw it, or to stop the answer
    /// that carries it (``cancel(message:)``).
    ///
    /// - Parameter message: The message the caller sent.
    /// - Returns: The final reply of its answer.
    /// - Throws: What its answer throws.
    func awaitAnswer(of message: SessionMessage) async throws -> String {
        try await withTaskCancellationHandler {
            try await message.answer.value()
        } onCancel: {
            message.answer.requestCancel()
            Task { await self.cancel(message: message) }
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
    /// its message waits for a later submission.
    ///
    /// - Throws: ``GenerationQueueError/waitInsideOpenSubmission(model:)``.
    func refuseWaitInsideOpenSubmission() throws {
        if ModelCallMark.current?.isOpenModelCall(of: id) == true {
            throw GenerationQueueError.waitInsideOpenSubmission(model: model)
        }
        try backend.generationQueue?.refuseWaitInsideOpenSubmission()
    }

    /// What one submission runs for the reader of its first message.
    ///
    /// A reply runs the respond call of ``backend``, under the grammar of the
    /// session. A stream runs the stream call, with no grammar, and gives
    /// each fragment to its reader.
    ///
    /// - Parameters:
    ///   - reader: The reader of the first message of the submission.
    ///   - ceiling: The token ceiling of the submission.
    /// - Returns: The work of the submission.
    func submissionWork(for reader: MessageReader, responseTokenCeiling ceiling: ResponseTokenCeiling) -> SubmissionWork {
        switch reader {
        case .reply:
            return SubmissionWork(
                grammar: grammar, onEvent: nil,
                body: respondBody(grammar: grammar, responseTokenCeiling: ceiling.resolved))
        case .textStream(let continuation):
            // A `String` element cannot report a restart, so this surface
            // delivers the text and nothing else — see
            // ``SessionEvent/textReset``, which the event stream carries in
            // its place.
            return SubmissionWork(grammar: nil, onEvent: nil) { composedPrompt in
                try await self.streamGeneratingBody(
                    composedPrompt: composedPrompt, responseTokenCeiling: ceiling.resolved, into: continuation,
                    wrapFragment: { $0.text.isEmpty ? [] : [$0.text] })
            }
        case .eventStream(let continuation):
            return SubmissionWork(grammar: nil, onEvent: { continuation.yield($0) }) { composedPrompt in
                try await self.streamGeneratingBody(
                    composedPrompt: composedPrompt, responseTokenCeiling: ceiling.resolved, into: continuation,
                    wrapFragment: Self.sessionEvents(for:))
            }
        }
    }

    /// Streams a text response to a prompt as it is produced, recording the
    /// call. Sends one stream message, and finishes the stream with its
    /// answer. Cancelling the stream cancels the waiting `Task`, which
    /// cancels the message.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model as the ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        Self.wrapAsyncStream { continuation in
            _ = try await self.sendAndAwaitAnswer(
                text: prompt, requestedMaxTokens: maxTokens, reader: .textStream(continuation), entryPoint: .stream)
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

    /// Runs `backend.streamResponseFragments(to:maxTokens:)`, forwarding each
    /// fragment through `wrapFragment` to `continuation` and accumulating the
    /// text. A fragment marked ``ResponseFragment/restartsResponse`` replaces
    /// the accumulated text.
    ///
    /// - Parameters:
    ///   - composedPrompt: The prompt, already composed with the outbox drain.
    ///   - maxTokens: The ceiling to give the backend, as
    ///     ``responseTokenCeiling(requested:contextTokens:)`` derives it.
    ///   - continuation: The stream continuation each element is yielded to.
    ///   - wrapFragment: Wraps one fragment into zero or more elements.
    /// - Returns: The accumulated, unwrapped response text.
    /// - Throws: Any error thrown by the model, or `CancellationError` when
    ///   the model call was cancelled during the stream.
    func streamGeneratingBody<Element: Sendable>(
        composedPrompt: String,
        responseTokenCeiling maxTokens: Int?,
        into continuation: AsyncThrowingStream<Element, Error>.Continuation,
        wrapFragment: @Sendable (ResponseFragment) -> [Element]
    ) async throws -> String {
        var response = ""
        // This turn's stall watch counts real increments (task ^z6xcmnh):
        // declared here so a streaming turn that has produced nothing yet is
        // still reported as one the session can see fragments on, and noted per
        // append below so the report is measured from the last one. A fragment
        // with no text still reports an append: a tool call, a tool result, or
        // a reasoning entry (task ^4799jxg).
        observeGenerationFragments()
        for try await fragment in backend.streamResponseFragments(
            to: composedPrompt, maxTokens: maxTokens)
        {
            noteGenerationProgress(fragment.progress)
            for element in wrapFragment(fragment) {
                continuation.yield(element)
            }
            response = fragment.restartsResponse ? fragment.text : response + fragment.text
        }
        // An `AsyncThrowingStream` whose consumer is cancelled *ends* — its
        // `next()` returns `nil` rather than throwing — so a cancelled streaming
        // submission would otherwise fall out of that loop holding a
        // half-produced `response` and be reported as a submission that simply
        // finished, indexed recording and all. It did not finish: it was cut
        // short (see ``RoutedSession/cancelCurrentTurn()``). Raising it here
        // routes a truncated stream into the same failed-submission handling
        // every other mid-generation failure takes, so the caller can tell the
        // two apart.
        // Whatever was already yielded stays yielded — a cancelled stream is
        // truncated, never retracted.
        try Task.checkCancellation()
        return response
    }

    /// See ``RoutedSession/streamEvents(to:maxTokens:)``. Sends one stream
    /// message, and finishes the stream with its answer. Cancelling the
    /// stream cancels the waiting `Task`, which cancels the message.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     resolved context of the model as the ceiling.
    /// - Returns: A stream of session events, finishing when generation
    ///   completes or throwing if it fails.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error> {
        Self.wrapAsyncStream { continuation in
            _ = try await self.sendAndAwaitAnswer(
                text: prompt, requestedMaxTokens: maxTokens, reader: .eventStream(continuation), entryPoint: .stream)
        }
    }

    /// See ``RoutedSession/streamSessionEvents()``. Registers a continuation in
    /// ``sessionEventSubscriptions`` with unbounded buffering. The termination
    /// handler captures `self` weakly and drops the subscription.
    func streamSessionEvents() -> AsyncStream<SessionEvent> {
        let subscriptionId = ULID.generate()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SessionEvent.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.dropSessionEventSubscription(subscriptionId) }
        }
        sessionEventSubscriptions[subscriptionId] = continuation
        return stream
    }

    /// Forgets one ``streamSessionEvents()`` subscription.
    ///
    /// - Parameter subscriptionId: The subscription's id.
    private func dropSessionEventSubscription(_ subscriptionId: ULID) {
        sessionEventSubscriptions.removeValue(forKey: subscriptionId)
    }

    /// Fans one session-scoped event out to every live
    /// ``streamSessionEvents()`` subscription.
    ///
    /// - Parameter event: The event to deliver.
    func emitSessionScopedEvent(_ event: SessionEvent) {
        for continuation in sessionEventSubscriptions.values {
            continuation.yield(event)
        }
    }

    /// Finishes every live ``streamSessionEvents()`` subscription, so a
    /// consumer ends when the session does. Clears the map, so a second
    /// ``close()`` has nothing left to finish.
    func finishSessionEventSubscriptions() {
        for continuation in sessionEventSubscriptions.values {
            continuation.finish()
        }
        sessionEventSubscriptions.removeAll()
    }

    /// The events one streamed ``ResponseFragment`` implies, in yield order.
    /// A restarting fragment yields ``SessionEvent/textReset`` first. Non-empty
    /// text follows as ``SessionEvent/textDelta(_:)``. These events bypass
    /// ``emitSessionScopedEvent(_:)``.
    ///
    /// - Parameter fragment: The fragment just received from the backend.
    /// - Returns: The events to yield for it, in order.
    static func sessionEvents(for fragment: ResponseFragment) -> [SessionEvent] {
        let reset: [SessionEvent] = fragment.restartsResponse ? [.textReset] : []
        return fragment.text.isEmpty ? reset : reset + [.textDelta(fragment.text)]
    }
}
