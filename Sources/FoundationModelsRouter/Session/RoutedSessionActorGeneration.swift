/// ``RoutedSessionActor``'s generation surface: the response, chunk-stream, and
/// event-stream entry points a caller drives, plus the session-scoped event
/// subscriptions a host watches a whole session through.
extension RoutedSessionActor {
    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Routes through the guided path when ``grammar`` is set, constraining the
    /// response to it through the backend's whole-chunk xgrammar entry point;
    /// otherwise runs the plain path. Both funnel through the same
    /// ``generate(grammar:_:)`` chokepoint.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        // `backend` is this session's own persistent generation object — never
        // recreated per call — so turns accumulate conversation state. A guided
        // session constrains every response to its grammar, through the
        // backend's whole-chunk xgrammar entry point; an unguided session takes
        // the plain path. Both funnel through the same chokepoint, which stamps
        // the grammar (or `nil`) onto each event and composes `prompt` with
        // whatever the outbox drains for this turn (see
        // ``generate(grammar:prompt:_:)``).
        try await generate(grammar: grammar, prompt: prompt, respondBody(grammar: grammar, maxTokens: maxTokens))
    }

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// Wraps ``streamGenerating(prompt:maxTokens:into:)`` via ``wrapAsyncStream(_:)``,
    /// forwarding each produced chunk to the stream's continuation and
    /// finishing it when generation completes or throws; cancelling the
    /// stream cancels the underlying `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        Self.wrapAsyncStream { continuation in
            try await self.streamGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
        }
    }

    /// Wraps `body` in an `AsyncThrowingStream`, running it inside a
    /// cancellable `Task` that finishes the stream — with or without an
    /// error — when `body` returns or throws.
    ///
    /// The `AsyncThrowingStream`/`Task`/`onTermination` scaffolding
    /// ``streamResponse(to:maxTokens:)`` and ``streamEvents(to:maxTokens:)``
    /// both need, differing only in the element type and the streaming work
    /// itself — factored out once here rather than duplicated per method.
    /// `static` (not an instance method) because it touches no actor state of
    /// its own; `body` captures whatever isolated state it needs (typically
    /// `self`) instead.
    ///
    /// - Parameter body: The streaming work, given the stream's own
    ///   continuation to yield elements to.
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

    /// Runs `backend.streamResponse(to:maxTokens:)`, forwarding each produced
    /// chunk through `wrapChunk` to `continuation` and accumulating the raw
    /// text for the chokepoint's close event.
    ///
    /// Shared by ``streamGenerating(prompt:maxTokens:into:)`` and
    /// ``streamEventsGenerating(prompt:maxTokens:into:)``, which differ only in
    /// their continuation's element type and how a chunk is wrapped for it
    /// (verbatim vs ``SessionEvent/textDelta(_:)``) — extracted so that
    /// difference cannot drift between the two call sites.
    ///
    /// - Parameters:
    ///   - composedPrompt: The prompt, already composed with whatever the
    ///     outbox drained for this turn, to stream a response to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    ///   - continuation: The stream continuation each wrapped chunk is yielded to.
    ///   - wrapChunk: Wraps a raw text chunk into `continuation`'s element type.
    /// - Returns: The accumulated, unwrapped response text.
    /// - Throws: Any error thrown by the model, or `CancellationError` when this
    ///   turn's model call was cancelled part-way through the stream.
    private func streamGeneratingBody<Element>(
        composedPrompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<Element, Error>.Continuation,
        wrapChunk: @Sendable (String) -> Element
    ) async throws -> String {
        var response = ""
        for try await chunk in backend.streamResponse(to: composedPrompt, maxTokens: maxTokens) {
            continuation.yield(wrapChunk(chunk))
            response += chunk
        }
        // An `AsyncThrowingStream` whose consumer is cancelled *ends* — its
        // `next()` returns `nil` rather than throwing — so a cancelled streaming
        // turn would otherwise fall out of that loop holding a half-produced
        // `response` and be reported as a turn that simply finished, indexed
        // recording and all. It did not finish: it was cut short (see
        // ``RoutedSession/cancelCurrentTurn()``). Raising it here routes a
        // truncated stream into the same failed-turn handling every other
        // mid-generation failure takes, so the caller can tell the two apart.
        // Whatever was already yielded stays yielded — a cancelled stream is
        // truncated, never retracted.
        try Task.checkCancellation()
        return response
    }

    /// Runs the recorder-bracketed streaming generation, forwarding each chunk
    /// the model produces to `continuation`.
    ///
    /// Extracted from ``streamResponse(to:)`` so that method's stream/`Task`
    /// scaffolding stays shallow: the bracketed `for`-loop lives here instead of
    /// nesting inside the continuation closure.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    ///   - continuation: The stream continuation each produced chunk is yielded to.
    /// - Throws: Any error thrown by the model, after the chokepoint records the
    ///   close event.
    private func streamGenerating(
        prompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Accumulate the streamed chunks so the close event can carry the full
        // response body; the accumulated text is the recorded response, while the
        // caller has already received each chunk through the continuation.
        _ = try await generate(prompt: prompt) { composedPrompt in
            try await self.streamGeneratingBody(
                composedPrompt: composedPrompt,
                maxTokens: maxTokens,
                into: continuation,
                wrapChunk: { $0 }
            )
        }
    }

    /// Streams a rich event sequence for a prompt as it is produced,
    /// recording the call. See ``RoutedSession/streamEvents(to:maxTokens:)``
    /// for the full contract.
    ///
    /// Wraps ``streamEventsGenerating(prompt:maxTokens:into:)`` via
    /// ``wrapAsyncStream(_:)``, mirroring ``streamResponse(to:maxTokens:)``'s
    /// own scaffolding exactly — cancelling the stream cancels the underlying
    /// `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: A stream of session events, finishing when generation
    ///   completes or throwing if it fails.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error> {
        Self.wrapAsyncStream { continuation in
            try await self.streamEventsGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
        }
    }

    /// See ``RoutedSession/streamSessionEvents()``.
    ///
    /// Registers a fresh continuation in ``sessionEventSubscriptions`` and hands
    /// back its stream. Buffering is unbounded because these events are reports a
    /// consumer must not silently lose, and there are very few of them per turn —
    /// unlike the per-token text a turn stream carries.
    ///
    /// The termination handler runs outside this actor's isolation (the stream can
    /// end on any task, including by cancellation), so dropping the subscription
    /// has to hop back in through a `Task` — the one place an unstructured task is
    /// unavoidable here. It captures `self` weakly, so an abandoned stream never
    /// keeps a finished session alive.
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

    /// Forgets one ``streamSessionEvents()`` subscription, whose stream has
    /// finished or been abandoned.
    ///
    /// - Parameter subscriptionId: The subscription's id.
    private func dropSessionEventSubscription(_ subscriptionId: ULID) {
        sessionEventSubscriptions.removeValue(forKey: subscriptionId)
    }

    /// Fans one session-scoped event out to every live ``streamSessionEvents()``
    /// subscription — the route a turn that has no event stream of its own
    /// surfaces such an event through (see ``RoutedSession/streamSessionEvents()``).
    ///
    /// - Parameter event: The event to deliver.
    func emitSessionScopedEvent(_ event: SessionEvent) {
        for continuation in sessionEventSubscriptions.values {
            continuation.yield(event)
        }
    }

    /// Finishes every live ``streamSessionEvents()`` subscription, so a consumer
    /// looping over one ends when the session does rather than awaiting an event
    /// that can no longer arrive.
    ///
    /// Each `finish()` fires that subscription's termination handler, which drops
    /// it from ``sessionEventSubscriptions`` on its own; the map is cleared here
    /// too so a second ``close()`` has nothing left to finish.
    func finishSessionEventSubscriptions() {
        for continuation in sessionEventSubscriptions.values {
            continuation.finish()
        }
        sessionEventSubscriptions.removeAll()
    }

    /// Runs the recorder-bracketed streaming generation, forwarding each
    /// text chunk the model produces as a ``SessionEvent/textDelta(_:)`` and,
    /// once the turn's diff runs, every other ``SessionEvent`` it implies —
    /// to `continuation`.
    ///
    /// Extracted from ``streamEvents(to:maxTokens:)`` so that method's
    /// stream/`Task` scaffolding stays shallow, mirroring
    /// ``streamGenerating(prompt:maxTokens:into:)``'s own split for the
    /// plain-text stream.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    ///   - continuation: The stream continuation each produced event is
    ///     yielded to.
    /// - Throws: Any error thrown by the model, after the chokepoint records the
    ///   close event and yields whatever ``SessionEvent``s that close implied.
    private func streamEventsGenerating(
        prompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    ) async throws {
        // `onEvent` forwards the chokepoint's own diff-derived events (tool
        // calls/status, reasoning, the closing usage) to this same
        // continuation once the turn's diff runs — see
        // `generate(grammar:prompt:onEvent:_:)`. The live text itself goes
        // through the same accumulate-and-forward loop
        // `streamGenerating(prompt:maxTokens:into:)` uses, via
        // ``streamGeneratingBody(composedPrompt:maxTokens:into:wrapChunk:)``,
        // wrapping each chunk as a ``SessionEvent/textDelta(_:)`` instead of
        // yielding it verbatim.
        _ = try await generate(prompt: prompt, onEvent: { continuation.yield($0) }) { composedPrompt in
            try await self.streamGeneratingBody(
                composedPrompt: composedPrompt,
                maxTokens: maxTokens,
                into: continuation,
                wrapChunk: SessionEvent.textDelta
            )
        }
    }
}
