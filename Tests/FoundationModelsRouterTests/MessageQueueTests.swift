import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the ``RoutedSession`` message queue (task ^cbhpdjy, restated from
/// the prompt queue of task ndv3sc1): ``RoutedSession/send(_:)-(Transcript.Prompt)``,
/// ``RoutedSession/pendingMessages()``, ``RoutedSession/replace(id:prompt:)``,
/// ``RoutedSession/messageQueueDepth()`` and ``RoutedSession/cancel(message:)``,
/// race-safe against the point where the pump of the session takes a message
/// for its submission.
///
/// A sent message needs no driver: the pump starts a submission for it by
/// itself (`generation-queue.md`, section 5.4). Everything runs against stubs
/// — no MLX, no network, no GPU.
@Suite("Message queue: send, inspect, edit, cancel")
struct MessageQueueTests {
    // MARK: - Stub containers

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        let responseText: String

        /// The per-turn token counts the vended backend meters, or `nil` to
        /// meter nothing. A session whose backend meters nothing sends a
        /// ``SessionEvent/submissionEnded(_:)`` with no usage, so a test that
        /// wants a usage sets this.
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
    /// moment it is called — proof the pump already took the message for its
    /// submission — and then suspends on ``proceed`` until the test releases
    /// it. The fixture the race tests use to land a concurrent
    /// `cancel(message:)`/`replace(id:prompt:)`/`send(_:)` squarely inside a
    /// running submission.
    ///
    /// A plain mutable class rather than an actor, mirroring
    /// ``StubSessionBackend``: ``RoutedSessionActor`` only ever drives one
    /// backend method at a time (serialized by the session's one pump), so
    /// ``entries`` is never mutated concurrently with itself —
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
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

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
            "max_position_embeddings": 8192,
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
            .appendingPathComponent("MessageQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over
    /// `container`, recording through `recorder`, mounting `tools`.
    private static func makeSession(
        recorder: any TranscriptRecorder,
        container: any LoadedLLMContainer,
        tools: [any Tool] = [],
        pool: ModelPool = ModelPool()
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = Self.makeTempDir()
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(tools: tools), dir)
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

    /// The text of each `.prompt` event `recorder` holds, in record order.
    ///
    /// - Parameter recorder: The recorder of the session.
    /// - Returns: The prompt texts.
    private static func promptTexts(in recorder: InMemoryRecorder) async -> [String] {
        await recorder.events.filter { $0.kind == .prompt }.compactMap(\.text)
    }

    // MARK: - FIFO order

    @Test("messages sent while a submission runs reach the next submission together, in the order they were sent")
    @MainActor
    func sentMessagesReachTheModelInFIFOOrder() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.send("first")
        await backend.started.wait()
        _ = await session.send("second")
        _ = await session.send("third")

        backend.proceed.signal()
        await backend.started.wait()
        backend.proceed.signal()
        #expect(await session.becomesIdle())

        #expect(
            await Self.promptTexts(in: recorder) == ["first", "second" + RoutedSessionActor.messageSeparator + "third"])
    }

    @Test("send returns its id while the submission of the message still runs")
    @MainActor
    func sendReturnsBeforeItsAnswer() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        // The backend holds the submission, so a send that waited for its
        // answer could never get here.
        let id = await session.send("wake the pump")
        await backend.started.wait()
        #expect(await session.messageQueueDepth().running == [id])

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["wake the pump"])
    }

    @Test("a respond and a message sent before it each reach the model once, in the order they arrived")
    @MainActor
    func respondAndSentMessageKeepTheirOrder() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.send("queued")
        let directResponse = try await session.respond(to: "direct")
        #expect(directResponse == "stub response")
        #expect(await session.becomesIdle())

        // The pump can carry both in one submission, or one in each; either
        // way each prompt reaches the model once, and the sent one first.
        let prompts = await Self.promptTexts(in: recorder)
        #expect(prompts.joined(separator: RoutedSessionActor.messageSeparator) == "queued\n\ndirect")
        #expect(await session.pendingMessages().isEmpty)
    }

    // MARK: - pendingMessages(): send, replace, cancel

    @Test(
        "pendingMessages() reflects send, replace and cancel; a withdrawn message never reaches a prompt; a replaced message delivers its new content"
    )
    @MainActor
    func pendingMessagesReflectsSendReplaceCancel() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let blocking = Task { try await session.respond(to: "blocking turn") }
        await backend.started.wait()
        let firstId = await session.send("cancel me")
        let secondId = await session.send("original")

        var pending = await session.pendingMessages()
        #expect(pending.map { Self.text(of: $0.prompt) } == ["cancel me", "original"])

        #expect(await session.cancel(message: firstId) == .withdrawn)
        pending = await session.pendingMessages()
        #expect(pending.map(\.id) == [secondId])

        #expect(await session.replace(id: secondId, prompt: Self.prompt("edited")) == .applied)
        pending = await session.pendingMessages()
        #expect(pending.map { Self.text(of: $0.prompt) } == ["edited"])

        backend.proceed.signal()
        _ = try await blocking.value
        await backend.started.wait()
        backend.proceed.signal()
        #expect(await session.becomesIdle())

        // Only the edited content reached the model; the withdrawn text never
        // appears anywhere.
        #expect(await Self.promptTexts(in: recorder) == ["blocking turn", "edited"])
        #expect(await session.pendingMessages().isEmpty)
    }

    @Test("the recording holds no trace of a message withdrawn before its submission")
    @MainActor
    func withdrawnMessageLeavesNoRecordingTrace() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let blocking = Task { try await session.respond(to: "blocking turn") }
        await backend.started.wait()
        let id = await session.send("never delivered")
        #expect(await session.cancel(message: id) == .withdrawn)

        backend.proceed.signal()
        _ = try await blocking.value
        #expect(await session.becomesIdle())

        #expect(await recorder.events.allSatisfy { !($0.text?.contains("never delivered") ?? false) })
    }

    @Test("a session that gets no message records nothing at all, not even the session meta line, after a cancel and a depth read")
    @MainActor
    func sessionWithNoMessageRecordsNothing() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await session.cancel() == .nothingToCancel)
        #expect(await session.messageQueueDepth() == MessageQueueDepth(waiting: 0, running: []))

        // A session that never runs a submission never writes its `session`
        // meta line either — the same "writes no file at all until it
        // generates" invariant a fresh session upholds.
        #expect(await recorder.events.isEmpty)
    }

    // MARK: - A sent message carries the waiting mail

    @Test("a sent message's submission carries the pending mail as the preamble of its prompt")
    @MainActor
    func sentMessageComposesPendingEvents() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = OperationEvent(tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)
        _ = await session.send("what happened?")
        #expect(await session.becomesIdle())

        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        let expectedLine = OperationEventSegment.renderedLine(for: posted)
        #expect(promptEvent.text == expectedLine + "\n\nwhat happened?")
    }

    // MARK: - The pump delivers a settled run with no message

    /// The output the delivery test's background tool returns, so the
    /// terminal line the model hears is recognizable.
    private static let deliveredToolOutput = "background result: the job finished"

    @Test(
        "a settled run with no waiting message starts a delivery submission with no caller call: the model hears the terminal, with no wait call"
    )
    @MainActor
    func settledRunWithNoMessageRunsADeliverySubmission() async throws {
        let recorder = InMemoryRecorder()
        let container = BackgroundingLLMContainer()
        let gate = RunLatch()
        let (session, dir) = try await Self.makeSession(
            recorder: recorder, container: container,
            tools: [LatchedBackgroundToolRunner(name: "job", gate: gate, output: Self.deliveredToolOutput)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = try #require(container.lastBackend)

        // The first submission backgrounds the job; no message waits after it.
        _ = try await session.respond(to: "start the job")
        let token = try #require(await session.mailbox.backgroundRuns().first?.completionToken)
        #expect(await session.pendingMessages().isEmpty)

        await gate.open()
        let terminal = try await MountFixtures.settledTerminal(of: token, in: session.mailbox)

        // No caller call: the settlement is mail, and the pump of the session
        // starts the delivery submission by itself.
        #expect(
            await BoundedWait.conditionReached("the delivery submission reaching the backend") {
                backend.receivedPrompts.count == 2
            })
        #expect(await session.becomesIdle())

        // The model heard the terminal on that submission, and never called
        // wait: one tool call, and nothing left staged.
        let deliveryPrompt = try #require(backend.receivedPrompts.last)
        #expect(backend.receivedPrompts.count == 2)
        #expect(deliveryPrompt.contains(OperationEventSegment.renderedLine(for: terminal)))
        #expect(deliveryPrompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(backend.toolCallCount == 1)
        #expect(await session.outbox.pending().events.isEmpty)
    }

    @Test("mail that carries only progress starts no submission: the report stays staged for the next message")
    @MainActor
    func progressOnlyMailRunsNoSubmission() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = OperationEvent(tool: "shell", op: "run command", correlationID: "1", kind: .progress, detail: "12 lines so far")
        await session.outbox.post(event: progress)

        #expect(await session.becomesIdle())
        #expect(await recorder.events.isEmpty)
        #expect(await session.outbox.pending().events.map(\.event) == [progress])
    }

    // MARK: - A sent Transcript.Prompt flattens to backend text

    @Test(
        "send(_:) submits every .text segment of a prompt joined with no separator, skipping non-text segments"
    )
    @MainActor
    func sentPromptFlattensEveryTextSegment() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let event = OperationEvent(tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        _ = await session.send(
            Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "alpha ")),
                OperationEventSegment(id: "seg-1", content: event).transcriptSegment,
                .text(Transcript.TextSegment(content: "omega")),
            ]))
        #expect(await session.becomesIdle())

        // What the backend was actually asked: the two text contents adjacent,
        // with nothing inserted between them and nothing contributed by the
        // `.custom` segment. A separator here would change the prompt the model
        // sees on every multi-segment message.
        let events = await recorder.events
        let promptEvent = try #require(events.first { $0.kind == .prompt })
        #expect(promptEvent.text == "alpha omega")
    }

    // MARK: - Races against a running submission

    @Test(
        "cancel(message:) of a message the pump already took reports cancelledInSubmission; a model that ignores the cancel still records its answer"
    )
    @MainActor
    func cancelOfATakenMessageReportsCancelledInSubmission() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.send("racing prompt")
        // The backend has been asked to respond: the pump took the message.
        await backend.started.wait()

        #expect(await session.cancel(message: id) == .cancelledInSubmission)

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["racing prompt"])
    }

    @Test("replace racing a running submission reports alreadySent; the submission delivers the original content")
    @MainActor
    func replaceRacingARunningSubmissionReportsAlreadySent() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.send("original")
        await backend.started.wait()

        #expect(await session.replace(id: id, prompt: Self.prompt("too late")) == .alreadySent)

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["original"])
    }

    @Test("a message sent while a submission runs is not swept into it, and goes into the next submission")
    @MainActor
    func sendDuringASubmissionGoesIntoTheNextSubmission() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.send("first")
        await backend.started.wait()

        // Send a second message while the first submission runs.
        let secondId = await session.send("second")
        #expect(await session.pendingMessages().map(\.id) == [secondId])

        backend.proceed.signal()
        await backend.started.wait()
        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["first", "second"])
    }

    // MARK: - Message to submission to event correlation

    @Test("the submission of a sent message opens a frame that names the message, and its answer names it too")
    @MainActor
    func sentMessageTurnFrameNamesItsMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        let id = await session.send("queued prompt")
        #expect(await session.becomesIdle())
        await session.close()

        let events = await collect(stream)
        let starts = events.submissionStarts
        #expect(starts.map(\.messageIds) == [[id]])
        #expect(starts.map(\.cause) == [.message])
        #expect(events.answers.map(\.messageIds) == [[id]])
    }

    @Test("a respond opens a submission frame that names its one message, and its answer names the same message")
    @MainActor
    func respondTurnFrameNamesNoMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        _ = try await session.respond(to: "direct prompt")
        await session.close()

        // The caller of respond does not see the id of its message. The
        // submission and the answer must name the same one message.
        let events = await collect(stream)
        let start = try #require(events.submissionStarts.first)
        #expect(events.submissionStarts.count == 1)
        #expect(start.messageIds.count == 1)
        #expect(start.cause == .message)
        #expect(events.answers.map(\.messageIds) == [start.messageIds])
    }

    @Test("two answers on one session take distinct submission ids, numbered from 1")
    @MainActor
    func consecutiveTurnsTakeDistinctIds() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents()
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")
        await session.close()

        let events = await collect(stream)
        let expectedIds = [SubmissionID(1), SubmissionID(Self.secondSubmissionNumber)]
        #expect(events.submissionStarts.count == Self.consecutiveTurnCount)
        #expect(events.submissionStarts.map(\.submissionId) == expectedIds)
        #expect(events.submissionEnds.map(\.submissionId) == expectedIds)
        #expect(events.answers.count == Self.consecutiveTurnCount)
    }

    /// The number of the second submission of a session.
    private static let secondSubmissionNumber: UInt64 = 2

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

        // `respond(to:)` hands its caller a response, not a stream. The
        // session-scoped stream still gets the usage of its one submission
        // and the usage of its answer.
        let events = await collect(stream)
        let usages = events.submissionEnds.compactMap(\.usage)
        #expect(events.submissionEnds.count == 1)
        #expect(usages.map(\.tokensIn) == [Self.meteredInput])
        #expect(usages.map(\.tokensOut) == [Self.meteredOutput])
        let answerUsages = events.answers.compactMap(\.usage)
        #expect(answerUsages.map(\.tokensIn) == [Self.meteredInput])
        #expect(answerUsages.map(\.tokensOut) == [Self.meteredOutput])
    }

    /// The input tokens ``sessionStreamCarriesRespondTurnEvents()``'s backend
    /// meters for its one turn.
    private static let meteredInput = 11

    /// The output tokens ``sessionStreamCarriesRespondTurnEvents()``'s backend
    /// meters for its one turn.
    private static let meteredOutput = 5

    // MARK: - Queue depth

    @Test("the queue depth counts the waiting messages and names the messages of the running submission")
    @MainActor
    func messageQueueDepthCountsWaitingAndRunningMessages() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = await session.send("first")
        await backend.started.wait()
        let secondId = await session.send("second")

        // The first message runs; the second waits. The session owes both
        // an answer.
        let midFlight = await session.messageQueueDepth()
        #expect(midFlight.waiting == 1)
        #expect(midFlight.running == [firstId])
        #expect(midFlight.total == Self.sentMessageCount)

        backend.proceed.signal()
        await backend.started.wait()
        let secondFlight = await session.messageQueueDepth()
        #expect(secondFlight == MessageQueueDepth(waiting: 0, running: [secondId]))

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        let afterBoth = await session.messageQueueDepth()
        #expect(afterBoth == MessageQueueDepth(waiting: 0, running: []))
        #expect(afterBoth.total == 0)
    }

    /// How many messages ``messageQueueDepthCountsWaitingAndRunningMessages()``
    /// sends.
    private static let sentMessageCount = 2

    // MARK: - cancel(message:) at every point of a message

    @Test("cancel(message:) withdraws a message that waits behind a running submission")
    @MainActor
    func cancelMessageWithdrawsAWaitingMessage() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await session.send("blocking")
        await backend.started.wait()
        let id = await session.send("withdraw me")

        #expect(await session.cancel(message: id) == .withdrawn)
        #expect(await session.pendingMessages().isEmpty)

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["blocking"])
    }

    @Test("a respond whose message waits is withdrawn by cancel(message:): its caller gets CancellationError, and no submission carries it")
    @MainActor
    func cancelMessageWithdrawsAWaitingRespond() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        // Occupy the pump with a first respond.
        let blockingTurn = Task { try await session.respond(to: "blocking turn") }
        await backend.started.wait()

        // The second respond is a message that waits in the outbox. Its
        // caller never sees the id, so the test reads it off the queue.
        let waitingRespond = Task { try await session.respond(to: "waiting prompt") }
        #expect(
            await BoundedWait.conditionReached("the respond message waiting in the outbox") {
                await session.outbox.waitingMessageCount == 1
            })
        let id = try #require(await session.pendingMessages().first?.id)

        #expect(await session.cancel(message: id) == .withdrawn)

        backend.proceed.signal()
        _ = try await blockingTurn.value
        await #expect(throws: CancellationError.self) { try await waitingRespond.value }
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["blocking turn"])
    }

    @Test("cancel(message:) of a respond message in a running submission reports cancelledInSubmission")
    @MainActor
    func cancelMessageCancelsARunningRespond() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let turn = Task { try await session.respond(to: "racing prompt") }
        await backend.started.wait()
        let id = try #require(await session.messageQueueDepth().running.first)

        #expect(await session.cancel(message: id) == .cancelledInSubmission)

        backend.proceed.signal()
        _ = try? await turn.value
        #expect(await session.becomesIdle())
    }

    @Test("cancel(message:) reports alreadyAnswered for an answered message, and for an id that names no message")
    @MainActor
    func cancelMessageReportsAlreadyAnsweredForAFinishedMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await session.send("one and done")
        #expect(await session.becomesIdle())

        #expect(await session.cancel(message: id) == .alreadyAnswered)
        #expect(await session.cancel(message: MessageID()) == .alreadyAnswered)
    }
}
