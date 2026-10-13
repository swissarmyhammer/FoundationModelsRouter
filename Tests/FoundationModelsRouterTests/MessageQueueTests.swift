import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the ``RoutedSession`` mail queue (task ^cbhpdjy, `mailbox.md`,
/// section 5): ``RoutedSession/send(_:)-(Transcript.Prompt)``,
/// ``RoutedSession/pendingMessages()``, ``RoutedSession/replace(_:with:)``,
/// ``RoutedSession/mailQueueDepth()``, ``RoutedSession/cancel(_:)`` and
/// ``RoutedSession/cancelAll()``, race-safe against the point where the pump
/// of the session takes a mail for its submission.
///
/// A cancel and a replace are signals: each returns its ``SignalID`` at once,
/// and a test waits for its terminal event ``SessionEvent/signalDone(_:)``
/// before it checks the effect. A cancel and a replace act only on queued
/// mail. They never stop an answer that runs: the mail that the pump took
/// gets its answer. ``RoutedSession/cancelAll()`` also stops the running
/// answer: its mail gets ``SessionEvent/answerFailed(_:)`` at once.
///
/// A sent message needs no driver: the pump starts a submission for it by
/// itself (`generation-queue.md`, section 5.4). Everything runs against stubs
/// — no MLX, no network, no GPU.
@Suite("Message queue: send, inspect, edit, cancel")
struct MessageQueueTests {
    // MARK: - Stub containers

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        let responseText: String

        /// The token counts of each submission the vended backend meters, or `nil` to
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
    /// `cancel(_:)`/`replace(_:with:)`/`send(_:)` squarely inside a
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
    ) async throws -> (session: any RoutedSession, dir: URL) {
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

    // MARK: - Mail helpers

    /// The body of a user message in reply mode with the text `text`: the
    /// body that ``RoutedSession/send(_:)-(String)`` gives a message.
    ///
    /// - Parameter text: The prompt text.
    /// - Returns: The body.
    private static func userMessage(_ text: String) -> MailBody {
        .userMessage(prompt: text, options: UserMessageOptions())
    }

    /// The prompt text of each queued mail of `session`, in queue order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The texts. Run mail has no prompt text, so it is not in it.
    private static func pendingTexts(of session: any RoutedSession) async -> [String] {
        await session.pendingMessages().compactMap(\.promptText)
    }

    /// Whether `event` is the ``SessionEvent/answered(_:)`` of an answer
    /// that delivered the mail `id`.
    ///
    /// - Parameters:
    ///   - event: A terminal event.
    ///   - id: The id of the mail.
    /// - Returns: `true` when the answer names `id`.
    private static func isAnswer(_ event: SessionEvent, of id: MailID) -> Bool {
        if case .answered(let answer) = event {
            return answer.mailIds.contains(id)
        }
        return false
    }

    /// The text of each `.prompt` event `recorder` holds, in record order.
    ///
    /// - Parameter recorder: The recorder of the session.
    /// - Returns: The prompt texts.
    private static func promptTexts(in recorder: InMemoryRecorder) async -> [String] {
        await recorder.events.filter { $0.kind == .prompt }.compactMap(\.text)
    }

    /// Waits for the terminal event of `signal`, and expects it to be
    /// ``SessionEvent/signalDone(_:)``. The effect of a signal comes before
    /// that event, so a test checks the effect after this call.
    ///
    /// - Parameters:
    ///   - signal: The id that a signal call returned.
    ///   - session: The session of the signal.
    ///   - sourceLocation: The place of the call, for the issue.
    /// - Throws: When the wait ends with no terminal event.
    private static func expectSignalDone(
        _ signal: SignalID, on session: any RoutedSession, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal), sourceLocation: sourceLocation)
    }

    /// Reads `feed` to its end, with the origin of each event. Call it after
    /// ``RoutedSession/close()``, which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each output the feed delivered, in order.
    private static func outputs(of feed: AsyncStream<SessionOutput>) async -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        return outputs
    }

    // MARK: - FIFO order

    @Test("messages sent while a submission runs reach the next submission together, in the order they were sent")
    @MainActor
    func sentMessagesReachTheModelInFIFOOrder() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try session.send("first")
        await backend.started.wait()
        _ = try session.send("second")
        _ = try session.send("third")

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
        let id = try session.send("wake the pump")
        await backend.started.wait()
        #expect(await session.mailQueueDepth().running == [id])

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

        _ = try session.send("queued")
        let directResponse = try await session.respond(to: "direct")
        #expect(directResponse == "stub response")
        #expect(await session.becomesIdle())

        // The pump can carry both in one submission, or one in each; either
        // way each prompt reaches the model once, and the sent one first.
        let prompts = await Self.promptTexts(in: recorder)
        #expect(prompts.joined(separator: RoutedSessionActor.messageSeparator) == "queued\n\ndirect")
        #expect(await session.pendingMessages().isEmpty)
    }

    // MARK: - send(_:) refusals

    @Test(
        "send(_:) refuses a prompt with no .text segment and every prompt after close; a refused prompt never reaches the queue"
    )
    @MainActor
    func sendRefusesAPromptWithNoTextAndEveryPromptAfterClose() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: PromptRefusal.noTextSegment) { try session.send(Transcript.Prompt(segments: [])) }
        #expect(await session.pendingMessages().isEmpty)

        await session.close()
        #expect(throws: MailRefusal.closed) { try session.send("too late") }
        #expect(await session.pendingMessages().isEmpty)
        #expect(await recorder.events.isEmpty)
    }

    // MARK: - pendingMessages(): send, replace, cancel

    @Test(
        "pendingMessages() reflects send, replace and cancel; a cancelled message gets cancelled and never reaches a prompt; a replaced message keeps its id and delivers its new content"
    )
    @MainActor
    func pendingMessagesReflectsSendReplaceCancel() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let blocking = Task { try await session.respond(to: "blocking message") }
        await backend.started.wait()
        let firstId = try session.send("cancel me")
        let secondId = try session.send("original")

        #expect(await Self.pendingTexts(of: session) == ["cancel me", "original"])

        let cancelSignal = session.cancel(firstId)
        try await Self.expectSignalDone(cancelSignal, on: session)
        #expect(await session.pendingMessages().map(\.id) == [secondId])
        #expect(try await session.awaitTerminal(of: firstId) == .cancelled(firstId))

        let replaceSignal = session.replace(secondId, with: Self.userMessage("edited"))
        try await Self.expectSignalDone(replaceSignal, on: session)
        #expect(await Self.pendingTexts(of: session) == ["edited"])
        #expect(await session.pendingMessages().map(\.id) == [secondId])

        backend.proceed.signal()
        _ = try await blocking.value
        await backend.started.wait()
        backend.proceed.signal()
        #expect(Self.isAnswer(try await session.awaitTerminal(of: secondId), of: secondId))
        #expect(await session.becomesIdle())

        // Only the edited content reached the model; the cancelled text never
        // appears anywhere.
        #expect(await Self.promptTexts(in: recorder) == ["blocking message", "edited"])
        #expect(await session.pendingMessages().isEmpty)
        await session.close()
        let ledger = TerminalEventLedger(outputs: await Self.outputs(of: feed))
        ledger.expectExactlyOneTerminal(for: [firstId, secondId])
        ledger.expectExactlyOneTerminal(forSignals: [cancelSignal, replaceSignal])
    }

    @Test("the recording holds no trace of a message cancelled before its submission")
    @MainActor
    func withdrawnMessageLeavesNoRecordingTrace() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let blocking = Task { try await session.respond(to: "blocking message") }
        await backend.started.wait()
        let id = try session.send("never delivered")
        try await Self.expectSignalDone(session.cancel(id), on: session)
        #expect(try await session.awaitTerminal(of: id) == .cancelled(id))

        backend.proceed.signal()
        _ = try await blocking.value
        #expect(await session.becomesIdle())

        #expect(await recorder.events.allSatisfy { !($0.text?.contains("never delivered") ?? false) })
    }

    @Test(
        "a session that gets no message records nothing at all, not even the session meta line, after the cancel signals, a replace and a depth read"
    )
    @MainActor
    func sessionWithNoMessageRecordsNothing() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let stop = session.cancelAll()
        let cancel = session.cancel(MailID())
        let replace = session.replace(MailID(), with: Self.userMessage("nothing to change"))
        try await Self.expectSignalDone(stop, on: session)
        try await Self.expectSignalDone(cancel, on: session)
        try await Self.expectSignalDone(replace, on: session)
        #expect(await session.stopRunningWork() == false)
        #expect(await session.mailQueueDepth() == MailQueueDepth(waiting: 0, depthByKind: [:], running: []))

        // A session that never runs a submission never writes its `session`
        // meta line either — the same "writes no file at all until it
        // generates" invariant a fresh session upholds.
        #expect(await recorder.events.isEmpty)
        await session.close()
        // The signals found no mail: no mail has a terminal event, and each
        // signal sends only its own end.
        let ledger = TerminalEventLedger(outputs: await Self.outputs(of: feed))
        #expect(ledger.endedMailIds.isEmpty)
        ledger.expectExactlyOneTerminal(forSignals: [stop, cancel, replace])
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
        _ = try session.send("what happened?")
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
        let token = try #require(await session.runPlane.backgroundRuns().first?.completionToken)
        // No user-type mail waits. The queue holds only the progress mail of
        // the backgrounded run, and progress mail never starts a submission.
        #expect(session.waitingUserMailCount == 0)
        #expect(await session.pendingMessages().allSatisfy { $0.runEvent?.kind == .progress })

        await gate.open()
        let terminal = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)

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

    @Test(
        "mail that carries only progress starts no submission: the report stays queued as run mail for the next message"
    )
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

        // pendingMessages() shows the run mail, and the depth counts it by kind.
        #expect(await session.pendingMessages().compactMap(\.runEvent) == [progress])
        let depth = await session.mailQueueDepth()
        #expect(depth == MailQueueDepth(waiting: 1, depthByKind: [.runEvent: 1], running: []))
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
        _ = try session.send(
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
        "cancel(_:) of a message the pump already took sends no cancelled and never stops its answer: the mail gets answered"
    )
    @MainActor
    func cancelOfATakenMessageLeavesItsAnswerRunning() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let id = try session.send("racing prompt")
        // The backend has been asked to respond: the pump took the message.
        await backend.started.wait()

        let signal = session.cancel(id)
        try await Self.expectSignalDone(signal, on: session)
        #expect(await session.mailQueueDepth().running == [id])

        backend.proceed.signal()
        #expect(Self.isAnswer(try await session.awaitTerminal(of: id), of: id))
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["racing prompt"])
        await session.close()
        // The answer is the one terminal event of the mail: the signal sent
        // no cancelled.
        let ledger = TerminalEventLedger(outputs: await Self.outputs(of: feed))
        ledger.expectExactlyOneTerminal(for: [id])
        ledger.expectExactlyOneTerminal(forSignals: [signal])
    }

    @Test(
        "replace(_:with:) racing a running submission changes nothing; the submission delivers the original content, and the mail gets answered"
    )
    @MainActor
    func replaceRacingARunningSubmissionReportsAlreadySent() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try session.send("original")
        await backend.started.wait()

        try await Self.expectSignalDone(session.replace(id, with: Self.userMessage("too late")), on: session)
        #expect(await session.pendingMessages().isEmpty)

        backend.proceed.signal()
        #expect(Self.isAnswer(try await session.awaitTerminal(of: id), of: id))
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

        _ = try session.send("first")
        await backend.started.wait()

        // Send a second message while the first submission runs.
        let secondId = try session.send("second")
        #expect(await session.pendingMessages().map(\.id) == [secondId])

        backend.proceed.signal()
        await backend.started.wait()
        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["first", "second"])
    }

    @Test(
        "cancel(_:) from many tasks at once removes a queued message one time: exactly one signal sends cancelled, and the mail and each signal get one terminal event"
    )
    @MainActor
    func concurrentCancelsOfOneMessageRemoveItOnce() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let blockingId = try session.send("blocking")
        await backend.started.wait()
        let id = try session.send("cancel me from many tasks")

        let signals = await withTaskGroup(of: SignalID.self) { group in
            for _ in 0..<Self.concurrentCancelCount {
                group.addTask { session.cancel(id) }
            }
            var ids: [SignalID] = []
            for await signal in group {
                ids.append(signal)
            }
            return ids
        }
        #expect(Set(signals).count == Self.concurrentCancelCount)
        for signal in signals {
            try await Self.expectSignalDone(signal, on: session)
        }
        #expect(try await session.awaitTerminal(of: id) == .cancelled(id))

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.outputs(of: feed)
        // The one cancelled event comes from one of the signals.
        let cancelledOrigins = outputs.filter { $0.event == .cancelled(id) }.map(\.origin)
        #expect(cancelledOrigins.count == 1)
        #expect(cancelledOrigins.allSatisfy { origin in signals.contains { origin == .signal($0) } })
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [blockingId, id])
        ledger.expectExactlyOneTerminal(forSignals: signals)
        #expect(await Self.promptTexts(in: recorder) == ["blocking"])
    }

    /// How many tasks ``concurrentCancelsOfOneMessageRemoveItOnce()`` runs
    /// at the same time.
    private static let concurrentCancelCount = 8

    // MARK: - Message to submission to event correlation

    @Test("the submission of a sent message opens a frame that names the message, and its answer names it too")
    @MainActor
    func sentMessageSubmissionFrameNamesItsMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents().events
        let id = try session.send("queued prompt")
        #expect(await session.becomesIdle())
        await session.close()

        let events = await collect(stream)
        _ = eventsInsideAnswerFrame(events)
        let starts = events.submissionStarts
        #expect(starts.map(\.mailIds) == [[id]])
        #expect(starts.map(\.cause) == [.message])
        #expect(events.answers.map(\.mailIds) == [[id]])
    }

    @Test("a respond opens a submission frame that names its one message, and its answer names the same message")
    @MainActor
    func respondSubmissionFrameNamesItsOneMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents().events
        _ = try await session.respond(to: "direct prompt")
        await session.close()

        // The caller of respond does not see the id of its message. The
        // submission and the answer must name the same one message.
        let events = await collect(stream)
        _ = eventsInsideAnswerFrame(events)
        let start = try #require(events.submissionStarts.first)
        #expect(events.submissionStarts.count == 1)
        #expect(start.mailIds.count == 1)
        #expect(start.cause == .message)
        #expect(events.answers.map(\.mailIds) == [start.mailIds])
    }

    @Test("two answers on one session take distinct submission ids, numbered from 1")
    @MainActor
    func consecutiveAnswersTakeDistinctIds() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents().events
        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")
        await session.close()

        let events = await collect(stream)
        #expect(events.eventsInsideEachAnswerFrame().count == Self.consecutiveAnswerCount)
        let expectedIds = [SubmissionID(1), SubmissionID(Self.secondSubmissionNumber)]
        #expect(events.submissionStarts.count == Self.consecutiveAnswerCount)
        #expect(events.submissionStarts.map(\.submissionId) == expectedIds)
        #expect(events.submissionEnds.map(\.submissionId) == expectedIds)
        #expect(events.answers.count == Self.consecutiveAnswerCount)
    }

    /// The number of the second submission of a session.
    private static let secondSubmissionNumber: UInt64 = 2

    /// How many answers ``consecutiveAnswersTakeDistinctIds()`` drives.
    private static let consecutiveAnswerCount = 2

    @Test("the session-scoped stream carries the derived events of an answer that hands its caller a response")
    @MainActor
    func sessionStreamCarriesRespondAnswerEvents() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(
            recorder: recorder,
            container: BasicLLMContainer(usageIncrement: (input: Self.meteredInput, output: Self.meteredOutput))
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents().events
        _ = try await session.respond(to: "direct prompt")
        await session.close()

        // `respond(to:)` hands its caller a response, not a stream. The
        // session-scoped stream still gets the usage of its one submission
        // and the usage of its answer.
        let events = await collect(stream)
        _ = eventsInsideAnswerFrame(events)
        let usages = events.submissionEnds.compactMap(\.usage)
        #expect(events.submissionEnds.count == 1)
        #expect(usages.map(\.tokensIn) == [Self.meteredInput])
        #expect(usages.map(\.tokensOut) == [Self.meteredOutput])
        let answerUsages = events.answers.compactMap(\.usage)
        #expect(answerUsages.map(\.tokensIn) == [Self.meteredInput])
        #expect(answerUsages.map(\.tokensOut) == [Self.meteredOutput])
    }

    /// The input tokens ``sessionStreamCarriesRespondAnswerEvents()``'s backend
    /// meters for its one submission.
    private static let meteredInput = 11

    /// The output tokens ``sessionStreamCarriesRespondAnswerEvents()``'s backend
    /// meters for its one submission.
    private static let meteredOutput = 5

    // MARK: - Queue depth

    @Test(
        "the queue depth counts the waiting messages by kind and names the messages of the running submission"
    )
    @MainActor
    func mailQueueDepthCountsWaitingAndRunningMessages() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = try session.send("first")
        await backend.started.wait()
        let secondId = try session.send("second")

        // The first message runs; the second waits. The session owes both
        // an answer.
        let midFlight = await session.mailQueueDepth()
        #expect(midFlight.waiting == 1)
        #expect(midFlight.depthByKind == [.userMessage: 1])
        #expect(midFlight.running == [firstId])
        #expect(midFlight.total == Self.sentMessageCount)

        backend.proceed.signal()
        await backend.started.wait()
        let secondFlight = await session.mailQueueDepth()
        #expect(secondFlight == MailQueueDepth(waiting: 0, depthByKind: [:], running: [secondId]))

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        let afterBoth = await session.mailQueueDepth()
        #expect(afterBoth == MailQueueDepth(waiting: 0, depthByKind: [:], running: []))
        #expect(afterBoth.total == 0)
    }

    /// How many messages ``mailQueueDepthCountsWaitingAndRunningMessages()``
    /// sends.
    private static let sentMessageCount = 2

    // MARK: - cancel(_:) and cancelAll() at every point of a message

    @Test(
        "cancel(_:) removes a message that waits behind a running submission, one time only, and the message gets cancelled"
    )
    @MainActor
    func cancelMessageWithdrawsAWaitingMessage() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let blockingId = try session.send("blocking")
        await backend.started.wait()
        let id = try session.send("withdraw me")

        let first = session.cancel(id)
        let second = session.cancel(id)
        try await Self.expectSignalDone(second, on: session)
        #expect(await session.pendingMessages().isEmpty)
        #expect(try await session.awaitTerminal(of: id) == .cancelled(id))

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["blocking"])
        await session.close()
        // Only the first signal finds the mail.
        let outputs = await Self.outputs(of: feed)
        #expect(outputs.filter { $0.event == .cancelled(id) }.map(\.origin) == [.signal(first)])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [blockingId, id])
        ledger.expectExactlyOneTerminal(forSignals: [first, second])
    }

    @Test(
        "cancelAll() removes each waiting message in queue order, each gets cancelled, and the running answer ends at once with answerFailed"
    )
    @MainActor
    func cancelAllRemovesEachWaitingMessageInQueueOrder() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let runningId = try session.send("blocking")
        await backend.started.wait()
        let firstId = try session.send("first waiting")
        let secondId = try session.send("second waiting")

        let stop = session.cancelAll()
        let secondStop = session.cancelAll()
        try await Self.expectSignalDone(secondStop, on: session)
        #expect(await session.pendingMessages().isEmpty)
        #expect(try await session.awaitTerminal(of: firstId) == .cancelled(firstId))
        #expect(try await session.awaitTerminal(of: secondId) == .cancelled(secondId))
        // The backend still holds the model call, and the answer already
        // ended.
        let runningEnd = try await session.awaitTerminal(of: runningId)
        #expect(runningEnd == .answerFailed(AnswerFailure(mailIds: [runningId], reason: .cancelled)))

        backend.proceed.signal()
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["blocking"])
        await session.close()
        // Only the first signal finds queued mail, in queue order.
        let outputs = await Self.outputs(of: feed)
        let cancelled = outputs.filter { output in
            if case .cancelled = output.event { return true }
            return false
        }
        #expect(cancelled.map(\.event) == [.cancelled(firstId), .cancelled(secondId)])
        #expect(cancelled.map(\.origin) == [.signal(stop), .signal(stop)])
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [runningId, firstId, secondId])
        ledger.expectExactlyOneTerminal(forSignals: [stop, secondStop])
    }

    @Test(
        "a respond whose message waits is removed by cancel(_:): its caller gets CancellationError, and no submission carries it",
        .timeLimit(.minutes(1)))
    @MainActor
    func cancelMessageWithdrawsAWaitingRespond() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        // Occupy the pump with a first respond.
        let blockingAnswer = Task { try await session.respond(to: "blocking message") }
        await backend.started.wait()

        // The second respond is a message that waits in the queue. Its
        // caller never sees the id, so the test reads it off the queue.
        let waitingRespond = Task { try await session.respond(to: "waiting prompt") }
        // No event tells that the message joined the queue, so the test reads
        // the count until it holds. Neither wait below has a wall clock (task
        // ^v4zh807): a loaded machine only delays the change, and only the
        // `.timeLimit` of this test ends a wait for a change that never comes.
        try await AwaitedCondition.wait(until: { session.waitingUserMailCount == 1 })
        let id = try #require(await session.pendingMessages().first?.id)

        try await Self.expectSignalDone(session.cancel(id), on: session)
        #expect(try await session.awaitTerminal(of: id) == .cancelled(id))

        backend.proceed.signal()
        _ = try await blockingAnswer.value
        await #expect(throws: CancellationError.self) { try await waitingRespond.value }
        #expect(try await session.isIdleOnceThePumpEnds())
        #expect(await Self.promptTexts(in: recorder) == ["blocking message"])
    }

    @Test(
        "cancel(_:) of a respond message in a running submission sends no cancelled and never stops the answer: the respond gets its reply"
    )
    @MainActor
    func cancelOfARunningRespondLeavesTheAnswerRunning() async throws {
        let recorder = InMemoryRecorder()
        let backend = GatedStubBackend(responseText: "gated response")
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: GatedLLMContainer(backend: backend))
        defer { try? FileManager.default.removeItem(at: dir) }

        let feed = await session.streamSessionEvents()
        let answer = Task { try await session.respond(to: "racing prompt") }
        await backend.started.wait()
        let id = try #require(await session.mailQueueDepth().running.first)

        let signal = session.cancel(id)
        try await Self.expectSignalDone(signal, on: session)

        backend.proceed.signal()
        #expect(try await answer.value == "gated response")
        #expect(Self.isAnswer(try await session.awaitTerminal(of: id), of: id))
        #expect(await session.becomesIdle())
        #expect(await Self.promptTexts(in: recorder) == ["racing prompt"])
        await session.close()
        let ledger = TerminalEventLedger(outputs: await Self.outputs(of: feed))
        ledger.expectExactlyOneTerminal(for: [id])
        ledger.expectExactlyOneTerminal(forSignals: [signal])
    }

    @Test(
        "cancel(_:) and replace(_:with:) change nothing for an answered message and for an id that names no message; the answer stays the one terminal event"
    )
    @MainActor
    func cancelMessageReportsAlreadyAnsweredForAFinishedMessage() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder, container: BasicLLMContainer())
        defer { try? FileManager.default.removeItem(at: dir) }

        let stream = await session.streamSessionEvents().events
        let id = try session.send("one and done")
        #expect(await session.becomesIdle())

        let cancelOfAnswered = session.cancel(id)
        let cancelOfUnknown = session.cancel(MailID())
        let replaceOfAnswered = session.replace(id, with: Self.userMessage("too late"))
        try await Self.expectSignalDone(cancelOfAnswered, on: session)
        try await Self.expectSignalDone(cancelOfUnknown, on: session)
        try await Self.expectSignalDone(replaceOfAnswered, on: session)
        #expect(Self.isAnswer(try await session.awaitTerminal(of: id), of: id))
        #expect(await session.pendingMessages().isEmpty)
        await session.close()

        let events = await collect(stream)
        #expect(MailQueueFixtures.cancelledIds(in: events).isEmpty)
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [id])
        ledger.expectExactlyOneTerminal(forSignals: [cancelOfAnswered, cancelOfUnknown, replaceOfAnswered])
        #expect(await Self.promptTexts(in: recorder) == ["one and done"])
    }
}
