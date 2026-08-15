import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ndv3sc1: the ``RoutedSession`` prompt-queue surface over
/// ``SessionOutbox``'s turn-starting prompt queue —
/// ``RoutedSession/enqueue(prompt:)``/``RoutedSession/pendingPrompts()``/
/// ``RoutedSession/cancel(id:)``/``RoutedSession/replace(id:prompt:)`` plus
/// ``RoutedSession/dispatchNextPrompt()`` driver dispatch, race-safe against
/// ``SessionOutbox/drainForDispatch()``'s commit boundary.
///
/// Everything runs against stubs — no MLX, no network, no GPU.
@Suite("Prompt queue: enqueue, inspect, edit, cancel, driver dispatch")
struct PromptQueueTests {
    // MARK: - Stub containers

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        let responseText: String

        /// The per-turn token counts the vended backend meters, or `nil` to
        /// meter nothing — a session whose backend meters nothing derives no
        /// ``SessionEvent/turnEnded(_:)``, so a test that wants one sets this.
        let usageIncrement: (input: Int, output: Int)?

        init(responseText: String = "stub response", usageIncrement: (input: Int, output: Int)? = nil) {
            self.responseText = responseText
            self.usageIncrement = usageIncrement
        }
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: responseText)
            backend.usageIncrement = usageIncrement
            return backend
        }
    }

    /// A backend whose ``respond(to:maxTokens:)`` signals ``started`` the
    /// moment it is called — proof the turn's outbox drain has already
    /// committed — and then suspends on ``proceed`` until the test releases
    /// it. The fixture the commit-boundary race tests use to land a
    /// concurrent `cancel`/`replace`/`enqueue` squarely inside an in-flight
    /// dispatch's "already drained, not yet recorded" window.
    ///
    /// A plain mutable class rather than an actor, mirroring
    /// ``StubSessionBackend``: ``RoutedSessionActor`` only ever drives one
    /// backend method at a time (serialized by the session's own serial
    /// gate), so ``entries`` is never mutated concurrently with itself —
    /// only ``started``/``proceed`` (both real ``AsyncSemaphore``s) are ever
    /// touched from a second, concurrent task.
    private final class GatedStubBackend: LanguageModelSessionBackend, @unchecked Sendable {
        let responseText: String
        let started = AsyncSemaphore(value: 0)
        let proceed = AsyncSemaphore(value: 0)
        private var entries: [Transcript.Entry] = []

        init(responseText: String) {
            self.responseText = responseText
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            started.signal()
            await proceed.wait()
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            entries.append(
                .response(
                    Transcript.Response(segments: [.text(Transcript.TextSegment(content: responseText))])))
            return responseText
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in continuation.finish() }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            return try await respond(to: prompt, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend { self }
        func transcriptEntries() -> [Transcript.Entry] { entries }
        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
    }

    /// Always vends the same ``GatedStubBackend`` instance, so a test can
    /// hold a reference to its semaphores while the session drives it.
    private final class GatedLLMContainer: LoadedLLMContainer {
        let backend: GatedStubBackend
        init(backend: GatedStubBackend) {
            self.backend = backend
        }
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend { backend }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend { backend }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    private struct StubModelLoader: ModelLoader {
        let container: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return container
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    // MARK: - Fixtures

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over
    /// `container`, recording through `recorder`.
    private static func makeSession(
        recorder: any TranscriptRecorder,
        container: any LoadedLLMContainer
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = Self.makeTempDir()
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    // MARK: - Prompt <-> text helpers

    private static func prompt(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
    }

    private static func text(of prompt: Transcript.Prompt) -> String {
        for segment in prompt.segments {
            if case .text(let textSegment) = segment {
                return textSegment.content
            }
        }
        return ""
    }

    // MARK: - FIFO dispatch

    @Test("prompts enqueued dispatch afterward in FIFO order, one recorded turn each")
    @MainActor
    func enqueuedPromptsDispatchInFIFOOrder() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.enqueue(prompt: "first")
        _ = await session.enqueue(prompt: "second")
        _ = await session.enqueue(prompt: "third")

        let firstResponse = try await session.dispatchNextPrompt()
        let secondResponse = try await session.dispatchNextPrompt()
        let thirdResponse = try await session.dispatchNextPrompt()
        let fourthResponse = try await session.dispatchNextPrompt()

        #expect(firstResponse == "stub response")
        #expect(secondResponse == "stub response")
        #expect(thirdResponse == "stub response")
        #expect(fourthResponse == nil)

        let events = await recorder.events
        let promptTexts = events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["first", "second", "third"])
    }

    @Test("awaitQueuedWork() resumes a parked driver once a prompt is enqueued, and returns at once while work is still queued")
    @MainActor
    func awaitQueuedWorkWakesForQueuedPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        // Park a driver first, then enqueue. Whichever side runs first, the
        // waiter must complete: a wait that starts before the enqueue is
        // resumed by it, and a wait that starts after finds the queue
        // non-empty and returns at once.
        let waiter = Task { await session.awaitQueuedWork() }
        _ = await session.enqueue(prompt: "wake the driver")
        await waiter.value

        // The prompt is still queued, so a fresh wait returns immediately
        // rather than parking until more work arrives.
        await session.awaitQueuedWork()

        let dispatched = try await session.dispatchNextPrompt()
        #expect(dispatched == "stub response")
    }

    @Test("a direct respond(to:) call does not consume or drop a queued prompt")
    @MainActor
    func respondDoesNotConsumeQueuedPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let queuedId = await session.enqueue(prompt: "queued")

        let directResponse = try await session.respond(to: "direct")
        #expect(directResponse == "stub response")

        // The queued prompt is untouched by the unrelated direct turn: it
        // is not silently dequeued just because it happened to be waiting.
        let pending = await session.pendingPrompts()
        #expect(pending.map(\.id) == [queuedId])

        let dispatched = try await session.dispatchNextPrompt()
        #expect(dispatched == "stub response")

        let events = await recorder.events
        let promptTexts = events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["direct", "queued"])
    }

    // MARK: - pendingPrompts(): enqueue/edit/cancel lifecycle

    @Test(
        "pendingPrompts() reflects enqueue/replace/cancel; a cancelled prompt never produces a turn; a replaced prompt dispatches its edited content"
    )
    @MainActor
    func pendingPromptsReflectsEnqueueEditCancel() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = await session.enqueue(prompt: "cancel me")
        let secondId = await session.enqueue(prompt: "original")

        var pending = await session.pendingPrompts()
        #expect(pending.map { Self.text(of: $0.prompt) } == ["cancel me", "original"])

        let cancelResult = await session.cancel(id: firstId)
        #expect(cancelResult == .applied)

        pending = await session.pendingPrompts()
        #expect(pending.map(\.id) == [secondId])
        #expect(pending.map { Self.text(of: $0.prompt) } == ["original"])

        let replaceResult = await session.replace(id: secondId, prompt: Self.prompt("edited"))
        #expect(replaceResult == .applied)

        pending = await session.pendingPrompts()
        #expect(pending.map { Self.text(of: $0.prompt) } == ["edited"])

        let response = try await session.dispatchNextPrompt()
        #expect(response == "stub response")

        // Only the replaced prompt's edited content ever produced a turn —
        // the cancelled prompt's text never appears anywhere.
        let events = await recorder.events
        let promptTexts = events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["edited"])

        let finalPending = await session.pendingPrompts()
        #expect(finalPending.isEmpty)
    }

    @Test("the recorded transcript contains no trace of a still-pending (never dispatched) prompt")
    @MainActor
    func stillPendingPromptLeavesNoTranscriptTrace() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.enqueue(prompt: "never dispatched")

        let events = await recorder.events
        #expect(events.filter { $0.kind == .prompt }.isEmpty)
    }

    @Test("dispatchNextPrompt() on a fresh session with an empty queue records nothing at all, not even the session meta line")
    @MainActor
    func dispatchNextPromptOnEmptyQueueRecordsNothing() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let response = try await session.dispatchNextPrompt()
        #expect(response == nil)

        // A session that never actually runs a turn must never write its
        // `session` meta line either — the same "writes no file at all
        // until it generates" invariant a fresh session that never calls
        // respond()/streamResponse() upholds.
        let events = await recorder.events
        #expect(events.isEmpty)
    }

    // MARK: - dispatchNextPrompt() composes pending turn-riding events

    @Test("dispatchNextPrompt() composes pending turn-riding events into the queued prompt's turn")
    @MainActor
    func dispatchNextPromptComposesPendingEvents() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.enqueue(prompt: "what happened?")
        let posted = OperationEvent(tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        _ = try await session.dispatchNextPrompt()

        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        let expectedLine = OperationEventSegment.renderedLine(for: posted)
        #expect(promptEvent.text == expectedLine + "\n\nwhat happened?")
    }

    // MARK: - dispatchNextPrompt() flattens the queued prompt to backend text

    @Test(
        "dispatchNextPrompt() submits every .text segment of a queued prompt joined with no separator, skipping non-text segments"
    )
    @MainActor
    func dispatchNextPromptFlattensEveryTextSegment() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let event = OperationEvent(tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        _ = await session.enqueue(
            prompt: Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "alpha ")),
                OperationEventSegment(id: "seg-1", content: event).transcriptSegment,
                .text(Transcript.TextSegment(content: "omega")),
            ]))

        _ = try await session.dispatchNextPrompt()

        // What the backend was actually asked: the two text contents adjacent,
        // with nothing inserted between them and nothing contributed by the
        // `.custom` segment. A separator here would change the prompt the model
        // sees on every multi-segment queued turn.
        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.text == "alpha omega")
    }

    // MARK: - Commit-boundary race: cancel/replace/enqueue vs. an in-flight dispatch

    @Test("cancel racing an in-flight dispatch reports alreadySent; the in-flight turn is unaffected")
    @MainActor
    func cancelRacingInFlightDispatchReportsAlreadySent() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.enqueue(prompt: "racing prompt")

        let dispatchTask = Task { try await session.dispatchNextPrompt() }

        // Wait until the backend has actually been asked to respond — proof
        // the outbox's drain already committed this prompt's id.
        await backend.started.wait()

        let cancelResult = await session.cancel(id: id)
        #expect(cancelResult == .alreadySent)

        // Let the in-flight turn actually finish, unaffected by the race.
        backend.proceed.signal()
        let response = try await dispatchTask.value
        #expect(response == "gated response")

        let events = await recorder.events
        let promptTexts = events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["racing prompt"])
    }

    @Test("replace racing an in-flight dispatch reports alreadySent; the in-flight turn dispatches the original content")
    @MainActor
    func replaceRacingInFlightDispatchReportsAlreadySent() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.enqueue(prompt: "original")

        let dispatchTask = Task { try await session.dispatchNextPrompt() }
        await backend.started.wait()

        let replaceResult = await session.replace(id: id, prompt: Self.prompt("too late"))
        #expect(replaceResult == .alreadySent)

        backend.proceed.signal()
        _ = try await dispatchTask.value

        let events = await recorder.events
        let promptTexts = events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["original"])
    }

    @Test("a prompt enqueued while another turn is in flight is not swept into it, and dispatches on the next call")
    @MainActor
    func enqueueDuringInFlightTurnDispatchesNext() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.enqueue(prompt: "first")
        let dispatchTask = Task { try await session.dispatchNextPrompt() }
        await backend.started.wait()

        // Enqueue a second prompt while the first turn is already in flight.
        let secondId = await session.enqueue(prompt: "second")

        backend.proceed.signal()
        let firstResponse = try await dispatchTask.value
        #expect(firstResponse == "gated response")

        // The second prompt was never touched by the first turn's drain —
        // still pending, ready for the next dispatch.
        let pending = await session.pendingPrompts()
        #expect(pending.map(\.id) == [secondId])
    }

    // MARK: - Prompt to turn to event correlation

    /// Drains a session-scoped event stream into an array.
    ///
    /// The stream is finished by ``RoutedSession/close()``, so a caller drains
    /// it after closing the session it came from.
    ///
    /// - Parameter stream: The stream to drain.
    /// - Returns: Every event it yielded, in order.
    private static func collect(_ stream: AsyncStream<SessionEvent>) async -> [SessionEvent] {
        var events: [SessionEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// The turn-start records among `events`, in order.
    ///
    /// - Parameter events: The events to filter.
    /// - Returns: Each ``SessionEvent/turnStarted(_:)`` payload.
    private static func turnStarts(in events: [SessionEvent]) -> [TurnStart] {
        events.compactMap { event in
            guard case .turnStarted(let start) = event else { return nil }
            return start
        }
    }

    @Test("a dispatched prompt's turn opens a frame naming the prompt that caused it")
    @MainActor
    func dispatchedTurnFrameNamesItsPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        let id = await session.enqueue(prompt: "queued prompt")
        _ = try await session.dispatchNextPrompt()
        await session.close()

        let starts = Self.turnStarts(in: await Self.collect(stream))
        #expect(starts.count == 1)
        #expect(starts.first?.promptId == id)
    }

    @Test("a turn whose prompt came straight from its caller opens a frame with no prompt id")
    @MainActor
    func directTurnFrameNamesNoPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        _ = try await session.respond(to: "direct prompt")
        await session.close()

        let starts = Self.turnStarts(in: await Self.collect(stream))
        #expect(starts.count == 1)
        #expect(starts.first?.promptId == nil)
    }

    @Test("two turns on one session take distinct turn ids")
    @MainActor
    func consecutiveTurnsTakeDistinctIds() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")
        await session.close()

        let starts = Self.turnStarts(in: await Self.collect(stream))
        #expect(starts.count == Self.consecutiveTurnCount)
        #expect(starts.first?.turnId != starts.last?.turnId)
    }

    /// How many turns ``consecutiveTurnsTakeDistinctIds()`` drives.
    private static let consecutiveTurnCount = 2

    @Test("the session-scoped stream carries the derived events of a turn that hands its caller a response")
    @MainActor
    func sessionStreamCarriesRespondTurnEvents() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(
            recorder: recorder,
            container: BasicLLMContainer(usageIncrement: (input: Self.meteredInput, output: Self.meteredOutput))
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        _ = try await session.respond(to: "direct prompt")
        await session.close()

        // `respond(to:)` hands its caller a response, not a stream, so before
        // the fan-in this turn derived no events at all. The closing usage is
        // the proof it now does.
        let events = await Self.collect(stream)
        let usages = events.compactMap { event -> TokenUsage? in
            guard case .turnEnded(let usage) = event else { return nil }
            return usage
        }
        #expect(usages.map(\.tokensIn) == [Self.meteredInput])
        #expect(usages.map(\.tokensOut) == [Self.meteredOutput])
    }

    /// The input tokens ``sessionStreamCarriesRespondTurnEvents()``'s backend
    /// meters for its one turn.
    private static let meteredInput = 11

    /// The output tokens ``sessionStreamCarriesRespondTurnEvents()``'s backend
    /// meters for its one turn.
    private static let meteredOutput = 5

    // MARK: - Queue depth

    @Test("queue depth counts the waiting prompts and the one whose turn is already running")
    @MainActor
    func queueDepthCountsDispatchedWork() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = await session.enqueue(prompt: "first")
        _ = await session.enqueue(prompt: "second")

        let queuedOnly = await session.promptQueueDepth()
        #expect(queuedOnly.queued == Self.enqueuedPromptCount)
        #expect(queuedOnly.dispatched == nil)
        #expect(queuedOnly.total == Self.enqueuedPromptCount)

        let dispatchTask = Task { try await session.dispatchNextPrompt() }
        await backend.started.wait()

        // The dispatched prompt has left the queue but the session still owes
        // it a turn, so the total is unchanged while `queued` drops by one.
        let midFlight = await session.promptQueueDepth()
        #expect(midFlight.queued == Self.enqueuedPromptCount - 1)
        #expect(midFlight.dispatched == firstId)
        #expect(midFlight.total == Self.enqueuedPromptCount)

        backend.proceed.signal()
        _ = try await dispatchTask.value

        let afterTurn = await session.promptQueueDepth()
        #expect(afterTurn.queued == Self.enqueuedPromptCount - 1)
        #expect(afterTurn.dispatched == nil)
        #expect(afterTurn.total == Self.enqueuedPromptCount - 1)
    }

    /// How many prompts ``queueDepthCountsDispatchedWork()`` enqueues before it
    /// dispatches the first of them.
    private static let enqueuedPromptCount = 2

    // MARK: - Cancelling a prompt at every point before it generates

    @Test("cancelPrompt withdraws a prompt still waiting in the queue")
    @MainActor
    func cancelPromptWithdrawsQueuedPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.enqueue(prompt: "withdraw me")
        let result = await session.cancelPrompt(id: id)

        #expect(result == .withdrawn)
        #expect(await session.pendingPrompts().isEmpty)
    }

    @Test("a prompt whose dispatch is parked behind another turn is still withdrawable, and its dispatch then runs no turn")
    @MainActor
    func cancelPromptWithdrawsAPromptParkedOnTheTurnLock() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        // Occupy the turn lock with a direct turn.
        let blockingTurn = Task { try await session.respond(to: "blocking turn") }
        await backend.started.wait()

        // A dispatch for this prompt now parks on the turn lock: its drain has
        // not run, so the prompt is still in the queue and still withdrawable.
        let id = await session.enqueue(prompt: "parked prompt")
        let parkedDispatch = Task { try await session.dispatchNextPrompt() }

        let result = await session.cancelPrompt(id: id)
        #expect(result == .withdrawn)

        backend.proceed.signal()
        _ = try await blockingTurn.value
        // The parked dispatch never reaches the backend: its drain finds the
        // withdrawn prompt gone and it runs no turn at all.
        #expect(try await parkedDispatch.value == nil)

        let promptTexts = await recorder.events.filter { $0.kind == .prompt }.map(\.text)
        #expect(promptTexts == ["blocking turn"])
    }

    @Test("cancelPrompt cancels the turn of a prompt the drain already committed")
    @MainActor
    func cancelPromptCancelsDispatchedPromptsTurn() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.enqueue(prompt: "racing prompt")
        let dispatchTask = Task { try await session.dispatchNextPrompt() }
        await backend.started.wait()

        // Past the drain, `cancel(id:)` alone can only report `alreadySent`.
        #expect(await session.cancel(id: id) == .alreadySent)

        let result = await session.cancelPrompt(id: id)
        #expect(result == .turnCancelled)

        backend.proceed.signal()
        _ = try? await dispatchTask.value
    }

    @Test("cancelPrompt reports alreadyFinished for an id that names no queued or dispatched prompt")
    @MainActor
    func cancelPromptReportsAlreadyFinishedForFinishedPrompt() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.enqueue(prompt: "one and done")
        _ = try await session.dispatchNextPrompt()

        #expect(await session.cancelPrompt(id: id) == .alreadyFinished)
    }
}
