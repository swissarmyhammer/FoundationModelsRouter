import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task em16az8: ``RoutedLLM/makeLanguageModel()``, the FACTORY that
/// mints a fresh ``RecordingLanguageModel`` handle — a `LanguageModel`
/// conformer any caller can build a `LanguageModelSession(model:tools:instructions:)`
/// over directly and get recording, serial gating, and tool-calling support
/// with zero session plumbing.
///
/// Everything runs against a stub `LanguageModel` conformer wrapping a stub
/// ``LoadedLLMContainer`` and either an ``InMemoryRecorder`` or a
/// ``GatingRecorder`` wrapping one — so the suite needs no network and no
/// GPU. The stub model plays two scripts: a plain canned-response turn, and a
/// two-step tool-calling turn (emit `.toolCalls`, then — once the transcript
/// shows a `.toolOutput` — the final response), mirroring how a real model's
/// executor is invoked twice per tool-using turn.
@Suite("RecordingLanguageModel: recording LanguageModel handle vended by RoutedLLM")
struct RecordingLanguageModelTests {
    // MARK: - Concurrency observation

    /// Tracks how many stub-model calls are concurrently "in flight" (parked
    /// on ``releaseGate``, below), so a test can assert the model's shared
    /// serial gate never lets two calls overlap.
    private actor SerialObserver {
        private(set) var active = 0
        private(set) var maxActive = 0

        func enter() {
            active += 1
            maxActive = max(maxActive, active)
        }

        func exit() {
            active -= 1
        }
    }

    /// Records every transcript the stub model's executor observed on each
    /// call, in call order — the evidence for passthrough fidelity (the
    /// request ``RecordingLanguageModel``'s own executor received is exactly
    /// what the wrapped model observed, unmodified).
    private actor RecordedTranscripts {
        private(set) var transcripts: [Transcript] = []
        func record(_ transcript: Transcript) { transcripts.append(transcript) }
    }

    // MARK: - Stub underlying LanguageModel

    /// A configurable `LanguageModel` conformer standing in for the resident
    /// model ``RecordingLanguageModel`` wraps.
    ///
    /// On a plain turn it emits ``cannedResponseText`` directly. When
    /// ``toolName`` is set it instead plays a scripted two-step tool-calling
    /// turn: emits a `.toolCalls` event naming ``toolName`` while the
    /// transcript has not yet gained a `.toolOutput` entry, then
    /// ``cannedResponseText`` once one has — mirroring how a real model's
    /// executor is invoked twice per tool-using turn (once to request the
    /// call, once more with the tool's output folded into the transcript).
    ///
    /// When ``observer``/``releaseGate`` are set, every call parks on the
    /// release gate after recording entry into ``observer`` — the seam
    /// ``serialGateSerializesAcrossHandles()`` uses to prove two concurrent
    /// calls sharing one model's serial gate never overlap.
    private struct StubUnderlyingModel: LanguageModel {
        let cannedResponseText: String
        let toolName: String?
        let toolArgumentsJSON: String
        let transcripts: RecordedTranscripts
        let observer: SerialObserver?
        let releaseGate: AsyncSemaphore?

        init(
            cannedResponseText: String,
            toolName: String? = nil,
            toolArgumentsJSON: String = "{}",
            transcripts: RecordedTranscripts,
            observer: SerialObserver? = nil,
            releaseGate: AsyncSemaphore? = nil
        ) {
            self.cannedResponseText = cannedResponseText
            self.toolName = toolName
            self.toolArgumentsJSON = toolArgumentsJSON
            self.transcripts = transcripts
            self.observer = observer
            self.releaseGate = releaseGate
        }

        var capabilities: LanguageModelCapabilities {
            LanguageModelCapabilities(toolName == nil ? [] : [.toolCalling])
        }

        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(
                cannedResponseText: cannedResponseText,
                toolName: toolName,
                toolArgumentsJSON: toolArgumentsJSON,
                transcripts: transcripts,
                observer: observer,
                releaseGate: releaseGate
            )
        }

        /// Executor conformance driving the scripted plain/tool-calling
        /// behavior described on ``StubUnderlyingModel`` above, and recording
        /// every transcript it observes into ``Configuration/transcripts``.
        struct Executor: LanguageModelExecutor {
            /// Cache key the SDK uses to create and reuse this stub's
            /// executor. The reference-typed ``transcripts``/``observer``/
            /// ``releaseGate`` fields are compared/hashed by identity — they
            /// have no structural equality of their own — so two tests never
            /// conflate each other's recorders in the SDK's executor cache.
            struct Configuration: Sendable, Hashable {
                let cannedResponseText: String
                let toolName: String?
                let toolArgumentsJSON: String
                let transcripts: RecordedTranscripts
                let observer: SerialObserver?
                let releaseGate: AsyncSemaphore?

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.cannedResponseText == rhs.cannedResponseText
                        && lhs.toolName == rhs.toolName
                        && lhs.toolArgumentsJSON == rhs.toolArgumentsJSON
                        && lhs.transcripts === rhs.transcripts
                        && lhs.observer === rhs.observer
                        && lhs.releaseGate === rhs.releaseGate
                }

                func hash(into hasher: inout Hasher) {
                    hasher.combine(cannedResponseText)
                    hasher.combine(toolName)
                    hasher.combine(toolArgumentsJSON)
                    hasher.combine(ObjectIdentifier(transcripts))
                    hasher.combine(observer.map(ObjectIdentifier.init))
                    hasher.combine(releaseGate.map(ObjectIdentifier.init))
                }
            }

            typealias Model = StubUnderlyingModel

            private let configuration: Configuration

            init(configuration: Configuration) throws {
                self.configuration = configuration
            }

            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: StubUnderlyingModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                await configuration.transcripts.record(request.transcript)

                if let observer = configuration.observer, let releaseGate = configuration.releaseGate {
                    await observer.enter()
                    await releaseGate.wait()
                    await observer.exit()
                }

                guard let toolName = configuration.toolName else {
                    await channel.send(.response(action: .appendText(configuration.cannedResponseText, tokenCount: 1)))
                    return
                }

                let alreadyRanTool = request.transcript.contains { entry in
                    if case .toolOutput = entry { return true }
                    return false
                }
                guard alreadyRanTool else {
                    await channel.send(
                        .toolCalls(
                            action: .toolCall(
                                id: "call-1",
                                name: toolName,
                                action: .appendArguments(configuration.toolArgumentsJSON, tokenCount: 1)
                            )
                        )
                    )
                    return
                }
                await channel.send(.response(action: .appendText(configuration.cannedResponseText, tokenCount: 1)))
            }
        }
    }

    // MARK: - Test tool

    @Generable
    struct EchoArguments {
        let text: String
    }

    /// A real `FoundationModels.Tool` conformer the tool-using-turn test
    /// registers on the session, so the SDK's own machinery — not this
    /// suite — invokes it once it observes the stub model's `.toolCalls`
    /// event and folds the result back in as a `.toolOutput` entry.
    private struct EchoTool: Tool {
        let name = "echo"
        let description = "Echoes text back"

        func call(arguments: EchoArguments) async throws -> String {
            "echoed: \(arguments.text)"
        }
    }

    // MARK: - Stub container

    /// A ``LoadedLLMContainer`` exposing a ``StubUnderlyingModel`` as its
    /// ``LoadedLLMContainer/languageModel`` — the seam
    /// ``RoutedModel/makeLanguageModel()`` wraps. `makeSession(instructions:)`
    /// is never driven by this suite (only the raw `languageModel` surface
    /// is), so it returns a bare, unused ``StubSessionBackend``.
    private struct StubLanguageModelContainer: PlainTranscriptStubContainer {
        let model: StubUnderlyingModel

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }

        var languageModel: any LanguageModel { model }
    }

    // MARK: - Stubs (probe, embedder, metadata, loader)

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

    /// A ``ModelLoader`` that returns the given ``LoadedLLMContainer`` for
    /// every generation slot. No download, no GPU.
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
            .appendingPathComponent("RecordingLanguageModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with `container` for every generation slot, an
    /// explicit recorder, and a chosen recording level / redaction hook.
    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        recordingLevel: RecordingLevel = .full,
        redact: (@Sendable (String) -> String)? = nil,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            redact: redact,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    /// Spins cooperatively until `condition` holds or a bounded number of
    /// yields elapse, so a scheduler-ordered state change is observed without
    /// a fixed sleep.
    private static func spin(until condition: @Sendable () async -> Bool) async {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Per-handle identity

    @Test("two makeLanguageModel() calls mint distinct handles: different session ids and recording directories")
    @MainActor
    func perHandleIdentity() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "ok", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: InMemoryRecorder(),
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handleA = profile.standard.makeLanguageModel()
        let handleB = profile.standard.makeLanguageModel()

        #expect(handleA.state !== handleB.state)
        #expect(handleA.state.sessionId != handleB.state.sessionId)
        #expect(handleA.state.recordingDirectory != handleB.state.recordingDirectory)
    }

    // MARK: - Diff-on-generate + sync-at-turn-end

    @Test("generate diffs instructions+prompt; sync(session.transcript) at turn end records the final response")
    @MainActor
    func diffOnGenerateAndSyncRecordsFinalResponse() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "hello back", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        let response = try await session.respond(to: "hi there")
        #expect(response.content == "hello back")

        // The turn-final response isn't observable at the executor boundary:
        // only instructions+prompt are recorded so far.
        var events = await recorder.events
        #expect(events.map(\.kind) == [.session, .instructions, .prompt])

        await handle.sync(session.transcript)
        events = await recorder.events
        #expect(events.map(\.kind) == [.session, .instructions, .prompt, .response])
        #expect(events.last?.text == "hello back")
    }

    // MARK: - Passthrough fidelity + tool-using turn

    @Test("a tool-using turn passes toolCalls/toolOutput through the shared channel unmodified")
    @MainActor
    func toolUsingTurnEndToEnd() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(
            cannedResponseText: "final answer",
            toolName: "echo",
            toolArgumentsJSON: #"{"text":"hi"}"#,
            transcripts: transcripts
        )
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [EchoTool()], instructions: "use tools")
        let response = try await session.respond(to: "please echo hi")
        #expect(response.content == "final answer")

        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .instructions, .prompt, .toolCalls, .toolOutput])

        let toolOutputEvent = try #require(events.first { $0.kind == .toolOutput })
        #expect(toolOutputEvent.text == "echoed: hi")

        // Passthrough fidelity: the wrapped model observed exactly two calls
        // — the same request each time our own handle diffed — proving the
        // request/channel were forwarded unmodified, not paraphrased.
        let observed = await transcripts.transcripts
        #expect(observed.count == 2)
        #expect(observed[0].count == 2)  // instructions, prompt
        #expect(observed[1].count == 4)  // + toolCalls, toolOutput

        await handle.sync(session.transcript)
        let finalEvents = await recorder.events
        #expect(finalEvents.map(\.kind).last == .response)
        #expect(finalEvents.last?.text == "final answer")
    }

    // MARK: - sync idempotence

    @Test("sync is idempotent: calling it twice with the same transcript appends nothing the second time")
    @MainActor
    func syncIdempotent() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "ok", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "hi")

        await handle.sync(session.transcript)
        let afterFirstSync = await recorder.events
        #expect(afterFirstSync.map(\.kind) == [.session, .instructions, .prompt, .response])

        await handle.sync(session.transcript)
        let afterSecondSync = await recorder.events
        #expect(afterSecondSync == afterFirstSync)
    }

    // MARK: - Serial gate

    @Test("generate acquires the model's shared serial gate; two handles over the same model never overlap")
    @MainActor
    func serialGateSerializesAcrossHandles() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = SerialObserver()
        let releaseGate = AsyncSemaphore(value: 0)
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(
            cannedResponseText: "ok",
            transcripts: transcripts,
            observer: observer,
            releaseGate: releaseGate
        )
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: InMemoryRecorder(),
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handleA = profile.standard.makeLanguageModel()
        let handleB = profile.standard.makeLanguageModel()
        let serialGate = profile.standard.serialGate

        let sessionA = LanguageModelSession(model: handleA, tools: [])
        let sessionB = LanguageModelSession(model: handleB, tools: [])

        let taskA = Task { _ = try await sessionA.respond(to: "a") }
        await Self.spin(until: { await observer.active == 1 })
        #expect(serialGate.availablePermits == 0)

        // handleB's call queues on the shared gate rather than reaching the
        // model concurrently with handleA's still-parked call.
        let taskB = Task { _ = try await sessionB.respond(to: "b") }
        await Self.spin(until: { serialGate.waiterCount == 1 })
        #expect(await observer.active == 1)
        #expect(await observer.maxActive == 1)

        releaseGate.signal()
        _ = try await taskA.value

        await Self.spin(until: { await observer.active == 1 })
        releaseGate.signal()
        _ = try await taskB.value

        #expect(await observer.maxActive == 1)
    }

    // MARK: - Recording level gating

    @Test("RecordingLevel.off records nothing for a handle's turns")
    @MainActor
    func levelOffRecordsNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "ok", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            recordingLevel: .off,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "hi")
        await handle.sync(session.transcript)

        let events = await recorder.events
        #expect(events.isEmpty)
    }

    @Test("RecordingLevel.metadataOnly strips body text but keeps kinds and provenance")
    @MainActor
    func levelMetadataOnlyStripsBodies() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "a secret reply", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            recordingLevel: .metadataOnly,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "a secret prompt")
        await handle.sync(session.transcript)

        let events = await recorder.events
        #expect(events.contains { $0.kind == .prompt })
        #expect(events.contains { $0.kind == .response })
        #expect(events.allSatisfy { $0.text == nil })
        #expect(events.allSatisfy { $0.routerId == router.id })
    }

    // MARK: - Redaction

    @Test("the redact hook transforms recorded prompt and response text")
    @MainActor
    func redactHookTransformsText() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "a secret reply", transcripts: transcripts)
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: "secret", with: "***") }
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            recordingLevel: .full,
            redact: redact,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "a secret prompt")
        await handle.sync(session.transcript)

        let events = await recorder.events
        let prompt = try #require(events.first { $0.kind == .prompt })
        #expect(prompt.text == "a *** prompt")
        let response = try #require(events.first { $0.kind == .response })
        #expect(response.text == "a *** reply")
    }

    // MARK: - Usage stamping

    @Test("sync(_:usage:) stamps tokensIn/tokensOut on the synced turn-final response event")
    @MainActor
    func syncWithUsageStampsTokens() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "hello back", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "hi there")

        await handle.sync(session.transcript, usage: (input: 42, output: 7))

        let events = await recorder.events
        let response = try #require(events.first { $0.kind == .response })
        #expect(response.tokensIn == 42)
        #expect(response.tokensOut == 7)
    }

    @Test("sync(_:) without usage leaves tokensIn/tokensOut nil — unchanged from before usage stamping")
    @MainActor
    func syncWithoutUsageLeavesTokensNil() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "hello back", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")
        _ = try await session.respond(to: "hi there")

        await handle.sync(session.transcript)

        let events = await recorder.events
        let response = try #require(events.first { $0.kind == .response })
        #expect(response.tokensIn == nil)
        #expect(response.tokensOut == nil)
    }

    @Test("multi-turn sync stamps usage per-turn, not cumulatively")
    @MainActor
    func multiTurnSyncStampsPerTurnUsage() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let transcripts = RecordedTranscripts()
        let model = StubUnderlyingModel(cannedResponseText: "hello back", transcripts: transcripts)
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: recorder,
            cacheDir: dir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let handle = profile.standard.makeLanguageModel()
        let session = LanguageModelSession(model: handle, tools: [], instructions: "be terse")

        _ = try await session.respond(to: "first")
        await handle.sync(session.transcript, usage: (input: 10, output: 5))

        _ = try await session.respond(to: "second")
        await handle.sync(session.transcript, usage: (input: 7, output: 3))

        let events = await recorder.events
        let responses = events.filter { $0.kind == .response }
        #expect(responses.count == 2)
        #expect(responses[0].tokensIn == 10)
        #expect(responses[0].tokensOut == 5)
        #expect(responses[1].tokensIn == 7)
        #expect(responses[1].tokensOut == 3)
    }
}
