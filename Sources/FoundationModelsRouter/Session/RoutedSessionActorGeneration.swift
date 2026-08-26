/// ``RoutedSessionActor``'s generation surface: the response, chunk-stream, and
/// event-stream entry points a caller drives, plus the session-scoped event
/// subscriptions a host watches a whole session through.
extension RoutedSessionActor {
    /// The most drained continuation turns one ``respond(to:maxTokens:)`` call
    /// runs after its own turn. After this many rounds the call answers with
    /// what the last turn produced.
    static let backgroundRunDrainRoundLimit = 4

    /// The prompt each drained continuation turn carries. The settled runs'
    /// results precede it as that turn's preamble.
    static let drainedRunContinuationPrompt = """
        The background work you started has finished, and its results are above. \
        Answer the request now, from those results.
        """

    /// The prompt a delivery turn carries: the one ``dispatchNextPrompt()``
    /// runs when a settled run's terminal is staged and no prompt is queued.
    static let settledRunDeliveryPrompt = """
        Background work you started has settled, and its result is above. \
        Act on it, or say what you did with it.
        """

    /// Generates a complete text response to a prompt, recording the call.
    /// After its own turn, drains the run plane: awaits every background run
    /// in ``SessionMailbox`` and runs a further turn with the settled results,
    /// up to ``backgroundRunDrainRoundLimit`` rounds. The drain ends early
    /// when a run outlasts ``ToolContext/deadlineSecondsCeiling`` or when a
    /// cancellation reaches this call; it then answers with the last turn's
    /// answer. It does not sweep.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     model's default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model. A turn that throws is not
    ///   drained.
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
        // chokepoint released it on its way out — so the background runs, and any
        // other caller, are free to make progress while this call waits.
        //
        // Registered for the whole drain, and registered here rather than
        // per wait: the turn above cleared `currentTurnId` on its way out, and
        // this statement runs before the next suspension, so there is no
        // instant at which this call is in flight and a cancellation can find
        // nothing to land on.
        runPlaneDrainCount += 1
        defer { runPlaneDrainCount -= 1 }
        for _ in 0..<Self.backgroundRunDrainRoundLimit {
            // A cancelled turn is never drained. Cancellation does not always
            // reach this call as a thrown error: a background tool call answers
            // the cancellation by going to the background and returning its pending envelope
            // (see ``RoutedSession/cancelCurrentTurn()``), so the turn returns
            // a response and only the count says what happened. Draining then
            // would wait for — and re-prompt the model with — exactly the work
            // the caller asked to stop.
            guard cancelRequestCount == cancellationsBefore, !Task.isCancelled else { break }
            guard await settleBackgroundRuns(cancellationsBefore: cancellationsBefore) else { break }
            answer = try await generate(
                grammar: grammar, prompt: Self.drainedRunContinuationPrompt,
                respondBody(grammar: grammar, maxTokens: maxTokens))
        }
        return answer
    }

    /// Awaits the settlement of every run tracked on this session's mailbox at
    /// the moment of the call: one drain round. A settled run's terminal event
    /// is already in ``outbox`` when its settlement is observable here.
    ///
    /// - Parameter cancellationsBefore: The ``cancelRequestCount`` the
    ///   ``respond(to:maxTokens:)`` call started from, checked before each wait.
    /// - Returns: `true` when at least one run was tracked and every one left
    ///   the run plane. `false` when the run plane was empty, when a run
    ///   outlasted ``ToolContext/deadlineSecondsCeiling``, or when a
    ///   cancellation reached this call.
    private func settleBackgroundRuns(cancellationsBefore: UInt64) async -> Bool {
        let running = await mailbox.backgroundRuns()
        guard !running.isEmpty else { return false }
        for run in running {
            // Checked here, immediately before the wait registers its gate —
            // there is no suspension between the two, so a cancellation either
            // is seen here or finds the gate to resume.
            guard cancelRequestCount == cancellationsBefore, !Task.isCancelled else { return false }
            switch await awaitSettlement(of: run.completionToken) {
            case .mailbox(.deadlineElapsed), .cancelled:
                return false
            case .mailbox:
                continue
            }
        }
        return true
    }

    /// Awaits one background run's settlement, racing the mailbox's wait
    /// against task cancellation and against the gate registered in
    /// ``runPlaneDrainWaitGates`` for ``RoutedSession/cancelCurrentTurn()``.
    ///
    /// - Parameter completionToken: The background run's completion token.
    /// - Returns: Whichever answer arrived first.
    private func awaitSettlement(of completionToken: String) async -> RunPlaneDrainWaitOutcome {
        let gate = RaceGate<RunPlaneDrainWaitOutcome>()
        let waiterID = ULID.generate()
        runPlaneDrainWaitGates[waiterID] = gate
        defer { runPlaneDrainWaitGates.removeValue(forKey: waiterID) }
        let mailbox = self.mailbox
        Task {
            let outcome = await mailbox.wait(
                completionToken: completionToken, seconds: ToolContext.deadlineSecondsCeiling)
            gate.resume(with: .mailbox(outcome))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { gate.register(continuation: $0) }
        } onCancel: {
            gate.resume(with: .cancelled)
        }
    }

    /// Ends every run-plane drain wait suspended on this session, so a
    /// ``respond(to:maxTokens:)`` call suspended between its turns returns.
    /// Called by ``cancelCurrentTurn()`` when no turn is in flight. Nothing is
    /// swept; the runs stay running.
    func endRunPlaneDrainWaits() {
        // Copied out and the registry emptied before any resume, so this
        // cancellation reaches exactly the waits it found: a drain that goes on
        // to register another wait registers it into an empty registry, and no
        // resumed waiter's own removal races this one.
        let gates = Array(runPlaneDrainWaitGates.values)
        runPlaneDrainWaitGates.removeAll()
        for gate in gates {
            gate.resume(with: .cancelled)
        }
    }

    /// Whether a ``respond(to:maxTokens:)`` call on this session is suspended
    /// on a run-plane drain wait, between its turns.
    var isSuspendedOnRunPlaneDrainWait: Bool {
        !runPlaneDrainWaitGates.isEmpty
    }

    /// Streams a text response to a prompt as it is produced, recording the
    /// call. Cancelling the stream cancels the underlying `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     model's default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        Self.wrapAsyncStream { continuation in
            try await self.streamGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
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
    ///   - maxTokens: The maximum number of tokens to generate, or `nil`.
    ///   - continuation: The stream continuation each element is yielded to.
    ///   - wrapFragment: Wraps one fragment into zero or more elements.
    /// - Returns: The accumulated, unwrapped response text.
    /// - Throws: Any error thrown by the model, or `CancellationError` when
    ///   the model call was cancelled during the stream.
    private func streamGeneratingBody<Element: Sendable>(
        composedPrompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<Element, Error>.Continuation,
        wrapFragment: @Sendable (ResponseFragment) -> [Element]
    ) async throws -> String {
        var response = ""
        // This turn's stall watch counts real increments (task ^z6xcmnh):
        // declared here so a streaming turn that has produced nothing yet is
        // still reported as one the session can see fragments on, and noted per
        // fragment below so the report is measured from the last one.
        observeGenerationFragments()
        for try await fragment in backend.streamResponseFragments(
            to: composedPrompt, maxTokens: maxTokens)
        {
            noteGenerationFragment()
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
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     model's default ceiling.
    ///   - continuation: The stream continuation each chunk is yielded to.
    /// - Throws: Any error thrown by the model, after the close event is
    ///   recorded.
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

    /// See ``RoutedSession/streamEvents(to:maxTokens:)``. Cancelling the
    /// stream cancels the underlying `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     model's default ceiling.
    /// - Returns: A stream of session events, finishing when generation
    ///   completes or throwing if it fails.
    func streamEvents(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<SessionEvent, Error> {
        Self.wrapAsyncStream { continuation in
            try await self.streamEventsGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
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
    private static func sessionEvents(for fragment: ResponseFragment) -> [SessionEvent] {
        let reset: [SessionEvent] = fragment.restartsResponse ? [.textReset] : []
        return fragment.text.isEmpty ? reset : reset + [.textDelta(fragment.text)]
    }

    /// Runs the recorder-bracketed streaming generation, forwarding each text
    /// chunk as a ``SessionEvent/textDelta(_:)`` and, once the turn's diff
    /// runs, every other ``SessionEvent`` it implies, to `continuation`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the
    ///     model's default ceiling.
    ///   - continuation: The stream continuation each event is yielded to.
    /// - Throws: Any error thrown by the model, after the close event is
    ///   recorded and its events are yielded.
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

/// The outcome of one run-plane drain wait: the run's settlement or a
/// cancellation, whichever arrives first.
enum RunPlaneDrainWaitOutcome: Sendable {
    /// The mailbox answered the wait: the run settled, its token was unknown,
    /// or the run plane's deadline elapsed.
    case mailbox(WaitOutcome)

    /// A cancellation reached the draining call first, by the caller's task or
    /// by ``RoutedSession/cancelCurrentTurn()``. The run stays running.
    case cancelled
}
