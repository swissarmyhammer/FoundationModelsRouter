/// ``RoutedSessionActor``'s generation surface: the response, chunk-stream, and
/// event-stream entry points a caller drives, plus the session-scoped event
/// subscriptions a host watches a whole session through.
extension RoutedSessionActor {
    /// The most drained continuation turns one ``respond(to:maxTokens:)`` call
    /// runs after its own turn — the whole of the drain's termination rule.
    ///
    /// A drained turn hands the model results it did not have before, so it can
    /// start more background work and park more runs, which asks for another
    /// drain. That is a loop with no exit of its own, so the exit is stated
    /// here: **drain every parked run, round after round, up to this many
    /// rounds — then answer with whatever the last turn produced.** A `respond`
    /// that can spin forever is worse than one that returns early (task
    /// ^nmpejc5), so the bound is part of the design rather than a later
    /// safeguard.
    ///
    /// Four rounds, because the case the rule exists for is a model that
    /// chains background steps — start work, read it, start the next step —
    /// and four continuation turns cover a chain of that shape while keeping
    /// the worst case a caller can pay small and countable.
    static let parkedRunDrainRoundLimit = 4

    /// The prompt each drained continuation turn carries.
    ///
    /// The settled runs' own results ride ahead of it as that turn's preamble
    /// (see ``generate(grammar:prompt:onEvent:_:)``'s drain-on-turn
    /// composition), so this text only has to say what the preamble is and ask
    /// for the answer the caller is still waiting on.
    static let drainedRunContinuationPrompt = """
        The background work you started has finished, and its results are above. \
        Answer the request now, from those results.
        """

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Routes through the guided path when ``grammar`` is set, constraining the
    /// response to it through the backend's whole-chunk xgrammar entry point;
    /// otherwise runs the plain path. Both funnel through the same
    /// ``generate(grammar:prompt:onEvent:_:)`` chokepoint.
    ///
    /// **What this call drains, and what it does not.** The two planes drain at
    /// different times, and this is the surface where both are drained before
    /// the caller is answered:
    ///
    /// - The **content plane** — ``SessionOutbox``, the events long-running
    ///   work has posted — is drained at the top of *each* of this call's
    ///   turns, folded into that turn's prompt as a plain-text preamble. That
    ///   is the ordinary drain-on-turn every generation surface performs.
    /// - The **run plane** — ``SessionMailbox``, the runs a detached tool call
    ///   parked — is drained *after* this call's own turn: every parked run is
    ///   awaited to settlement, and a further turn is run so the settled
    ///   results reach the model in this same call. So a turn whose tool work
    ///   backgrounded still answers from that work's own output rather than
    ///   from the completion token the tool returned, and no caller has to make
    ///   the model call a `wait` tool to get there. Every run parked at each
    ///   round is drained, not just the first, and the drain covers the whole
    ///   run plane rather than only this turn's own parkings — "nothing left
    ///   parked when `respond` returns" is a statement about the session.
    /// - It **does not sweep**. Cancelling parked runs and synthesizing their
    ///   terminals is teardown, and belongs to ``close()`` alone
    ///   (``SessionMailbox/sweep()``). A drain waits for work to finish; a
    ///   sweep ends it.
    /// - It **does not change the streaming surfaces**.
    ///   ``streamResponse(to:maxTokens:)`` and ``streamEvents(to:maxTokens:)``
    ///   still return while a run they parked is in flight: backgrounding is
    ///   the feature there, and a consumer of those surfaces watches the run
    ///   plane itself.
    ///
    /// The drain terminates by the rule ``parkedRunDrainRoundLimit`` states.
    /// Two other things end it: a run that has not settled by the run plane's
    /// own ``ToolContext/waitSecondsCeiling``, since a further turn could not
    /// carry its result anyway; and a cancellation landing on this call —
    /// either ``RoutedSession/cancelCurrentTurn()`` (counted by
    /// ``cancelRequestCount``, because a detached tool call can answer a
    /// cancellation by detaching, so the turn returns a response rather than
    /// throwing) or the caller's own task being cancelled. A cancelled turn is
    /// never drained: whatever it parked stays parked, exactly as it did
    /// before this surface drained anything.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response — the last drained turn's,
    ///   when this call's own turn backgrounded work.
    /// - Throws: Any error thrown by the model. A turn that throws is never
    ///   drained: the failure reaches the caller as it always did, and whatever
    ///   the failed turn parked stays parked for ``close()``'s sweep.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        // `backend` is this session's own persistent generation object — never
        // recreated per call — so turns accumulate conversation state. A guided
        // session constrains every response to its grammar, through the
        // backend's whole-chunk xgrammar entry point; an unguided session takes
        // the plain path. Both funnel through the same chokepoint, which stamps
        // the grammar (or `nil`) onto each event and composes `prompt` with
        // whatever the outbox drains for this turn (see
        // ``generate(grammar:prompt:onEvent:_:)``).
        let cancellationsBefore = cancelRequestCount
        var answer = try await generate(
            grammar: grammar, prompt: prompt, respondBody(grammar: grammar, maxTokens: maxTokens))

        // The run-plane drain. Each round runs outside the turn lock — the
        // chokepoint released it on its way out — so the parked runs, and any
        // other caller, are free to make progress while this call waits.
        for _ in 0..<Self.parkedRunDrainRoundLimit {
            // A cancelled turn is never drained. Cancellation does not always
            // reach this call as a thrown error: a detached tool call answers
            // the cancellation by detaching and returning its pending envelope
            // (see ``RoutedSession/cancelCurrentTurn()``), so the turn returns
            // a response and only the count says what happened. Draining then
            // would wait for — and re-prompt the model with — exactly the work
            // the caller asked to stop.
            guard cancelRequestCount == cancellationsBefore, !Task.isCancelled else { break }
            guard await settleParkedRuns() else { break }
            answer = try await generate(
                grammar: grammar, prompt: Self.drainedRunContinuationPrompt,
                respondBody(grammar: grammar, maxTokens: maxTokens))
        }
        return answer
    }

    /// Awaits the settlement of every run parked on this session's mailbox at
    /// the moment of the call — one drain round.
    ///
    /// A settled run's terminal event has already reached ``outbox`` by the
    /// time its settlement is observable here: the detachment engine awaits
    /// that post before the run's settling handle resolves, and
    /// ``SessionMailbox/park(tool:op:kind:completionToken:settling:canceler:)``
    /// observes the same handle. So a round that reports `true` leaves the
    /// results staged for the next turn's own drain-on-turn composition to
    /// fold into the prompt.
    ///
    /// - Returns: `true` when at least one run was parked and every one of them
    ///   left the run plane — settled, or gone from it between this round's
    ///   snapshot and its own wait (``WaitOutcome/unknownToken``), which is the
    ///   same fact arriving a moment earlier. `false` when the run plane was
    ///   already empty, or when a run outlasted
    ///   ``ToolContext/waitSecondsCeiling`` and so is still parked: neither
    ///   case has a settled result for a further turn to carry.
    private func settleParkedRuns() async -> Bool {
        let parked = await mailbox.parkedRuns()
        guard !parked.isEmpty else { return false }
        for run in parked {
            let outcome = await mailbox.wait(
                completionToken: run.completionToken, seconds: ToolContext.waitSecondsCeiling)
            if case .deadlineElapsed = outcome { return false }
        }
        return true
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

    /// Runs `backend.streamResponseFragments(to:maxTokens:)`, forwarding each
    /// produced fragment's text through `wrapChunk` to `continuation` and
    /// accumulating the raw text for the chokepoint's close event.
    ///
    /// The accumulation is restart-aware: a fragment marked
    /// ``ResponseFragment/restartsResponse`` replaces the text so far rather
    /// than extending it, so a tool-using turn's accumulated text is the answer
    /// the SDK actually ends on — the same string
    /// ``respond(to:maxTokens:)`` returns — instead of that answer with the
    /// superseded pre-tool text stuck on the front (task ^w8dzvee, defect D2).
    /// Every fragment's text is still forwarded to `continuation` as it
    /// arrives, since a delivered chunk cannot be retracted and a live consumer
    /// is entitled to everything the model said. `wrapFragment` is what turns a
    /// restart into whatever the calling surface's element type can say about
    /// it — a ``SessionEvent/textReset`` ahead of the restarting text on the
    /// event stream, nothing at all on the plain text stream, whose `String`
    /// element cannot carry the report.
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
    ///   - continuation: The stream continuation each wrapped element is yielded to.
    ///   - wrapFragment: Wraps one fragment into zero or more elements of
    ///     `continuation`'s element type, in yield order.
    /// - Returns: The accumulated, unwrapped response text.
    /// - Throws: Any error thrown by the model, or `CancellationError` when this
    ///   turn's model call was cancelled part-way through the stream.
    private func streamGeneratingBody<Element: Sendable>(
        composedPrompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<Element, Error>.Continuation,
        wrapFragment: @Sendable (ResponseFragment) -> [Element]
    ) async throws -> String {
        var response = ""
        for try await fragment in backend.streamResponseFragments(
            to: composedPrompt, maxTokens: maxTokens)
        {
            for element in wrapFragment(fragment) {
                continuation.yield(element)
            }
            response = fragment.restartsResponse ? fragment.text : response + fragment.text
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
                // A `String` element cannot report a restart, so this surface
                // delivers the text and nothing else — see
                // ``SessionEvent/textReset``, which the event stream carries in
                // its place.
                wrapFragment: { $0.text.isEmpty ? [] : [$0.text] }
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

    /// The events one streamed ``ResponseFragment`` implies, in yield order.
    ///
    /// A restarting fragment yields ``SessionEvent/textReset`` first, so a
    /// consumer clears what it accumulated before the new response's text
    /// arrives and ends the turn holding exactly what
    /// ``respond(to:maxTokens:)`` returns. The text itself follows as an
    /// ordinary ``SessionEvent/textDelta(_:)`` either way — superseded text is
    /// still delivered, never withheld (task ^w8dzvee, defect D2).
    ///
    /// An empty-text fragment yields no `.textDelta`: the SDK can open a new
    /// response before any of its text exists, and an empty delta reports
    /// nothing while looking like output.
    ///
    /// The events built here are yielded straight to the per-turn stream's
    /// continuation and deliberately bypass
    /// ``RoutedSessionActor/emitSessionScopedEvent(_:)`` — the
    /// ``RoutedSession/streamSessionEvents()`` feed excludes the per-token
    /// text increments by contract; see that method for the reason.
    ///
    /// - Parameter fragment: The fragment just received from the backend.
    /// - Returns: The events to yield for it, in order.
    private static func sessionEvents(for fragment: ResponseFragment) -> [SessionEvent] {
        let reset: [SessionEvent] = fragment.restartsResponse ? [.textReset] : []
        return fragment.text.isEmpty ? reset : reset + [.textDelta(fragment.text)]
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
                wrapFragment: Self.sessionEvents(for:)
            )
        }
    }
}
