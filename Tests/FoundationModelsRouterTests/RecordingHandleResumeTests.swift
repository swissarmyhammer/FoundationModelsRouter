import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task qts4v0a: ``RoutedModel/makeLanguageModel(resuming:registry:)``,
/// the overload that resumes a previously recorded session into a fresh
/// ``RecordingLanguageModel`` handle.
///
/// Unlike a plain ``RoutedModel/makeLanguageModel()`` handle (whose last-seen
/// transcript starts empty), a resumed handle primes last-seen with the
/// resumed session's own reconstructed ``FoundationModels/Transcript`` — so its
/// first diff records only genuinely new entries — and nests its own
/// directory under the resumed session's, the same
/// lineage semantics ``RoutedSessionActor/fork(workingDirectory:)`` already
/// establishes for ``RoutedSession``. Pairing the returned handle and
/// transcript into `LanguageModelSession(model:tools:transcript:)` is also how
/// a resumed session finally gets real tools — the container-based
/// `restoreSessionTree`/`fork` path hardcodes `tools: []`.
///
/// Everything runs against a stub `LanguageModel` conformer wrapping a stub
/// ``LoadedLLMContainer`` and a ``JSONLRecorder`` writing into a temp
/// directory, so the suite needs no network and no GPU, and lineage can be
/// verified by reloading a ``TranscriptTree`` straight off disk.
@Suite("Recording handle resume: makeLanguageModel(resuming:) lineage and priming")
struct RecordingHandleResumeTests {
    // MARK: - Stub underlying LanguageModel

    /// A configurable `LanguageModel` conformer standing in for the resident
    /// model ``RecordingLanguageModel`` wraps.
    ///
    /// Behavior is driven purely by what each call observes, not by any fixed
    /// per-instance script, so the same stub instance can serve a toolless
    /// turn before a resume and a tool-using turn after it: with no enabled
    /// tool definitions it replies with ``plainResponseText`` directly; with
    /// one or more enabled it emits a `.toolCalls` event naming the first
    /// tool until the transcript shows a `.toolOutput` entry, then replies
    /// with ``toolResponseText`` — mirroring how a real model's executor is
    /// invoked twice per tool-using turn.
    private struct StubUnderlyingModel: LanguageModel {
        let plainResponseText: String
        let toolResponseText: String

        var capabilities: LanguageModelCapabilities {
            LanguageModelCapabilities([.toolCalling])
        }

        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(
                plainResponseText: plainResponseText, toolResponseText: toolResponseText)
        }

        struct Executor: LanguageModelExecutor {
            struct Configuration: Sendable, Hashable {
                let plainResponseText: String
                let toolResponseText: String
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
                guard let toolName = request.enabledToolDefinitions.first?.name else {
                    await channel.send(
                        .response(action: .appendText(configuration.plainResponseText, tokenCount: 1)))
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
                                action: .appendArguments(#"{"text":"hi"}"#, tokenCount: 1)
                            )
                        )
                    )
                    return
                }
                await channel.send(
                    .response(action: .appendText(configuration.toolResponseText, tokenCount: 1)))
            }
        }
    }

    // MARK: - Test tool

    @Generable
    struct UppercaseArguments {
        let text: String
    }

    /// A real `FoundationModels.Tool` conformer only ever attached to a
    /// resumed handle's session — never to the parent's — so a passing
    /// tool-using turn after resume proves resuming with a different tool set
    /// works.
    private struct UppercaseTool: Tool {
        let name = "uppercase"
        let description = "Uppercases text"

        func call(arguments: UppercaseArguments) async throws -> String {
            arguments.text.uppercased()
        }
    }

    // MARK: - Stub container

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
            .appendingPathComponent("RecordingHandleResumeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with `container` for every generation slot, an
    /// explicit recorder, and a durable recordings root (so a resumed handle
    /// has an on-disk `session.json`/`transcript.jsonl` tree to load).
    private static func makeRouter(
        container: any LoadedLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(
                chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    // MARK: - Child transcript holds only post-resume events, with correct lineage

    @Test("resuming primes lastSeen: the child's own transcript.jsonl holds only post-resume events, with correct parent lineage")
    @MainActor
    func resumeRecordsOnlyNewEventsWithCorrectLineage() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Record N entries via the parent handle.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "hi there")
        await parentHandle.sync(parentSession.transcript)
        let parentEntryCount = parentSession.transcript.count  // instructions, prompt, response == 3

        // Resume from the parent's session id and continue one turn.
        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        #expect(restored.count == parentEntryCount)

        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "continue please")
        await childHandle.sync(childSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)

        // The child's OWN transcript.jsonl contains only post-resume events —
        // never the whole restored history re-recorded into a fresh directory.
        let childOwnEvents = try tree.events(forSession: childHandle.state.sessionId)
        #expect(childOwnEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(childOwnEvents.contains { $0.kind == .prompt && $0.text == "continue please" })

        // The parent's own transcript.jsonl is untouched.
        let parentOwnEvents = try tree.events(forSession: parentHandle.state.sessionId)
        #expect(parentOwnEvents.map(\.kind) == [.session, .instructions, .prompt, .response])

        // Lineage: the child's directory nests under the parent's, and its own
        // sidecar records the fork point.
        let childNode = try #require(tree.session(childHandle.state.sessionId))
        #expect(childNode.parentId == parentHandle.state.sessionId)
        #expect(childNode.sidecar.forkedAtEntryCount == parentEntryCount)
    }

    // MARK: - Different tool set

    @Test("resuming with a different tool set drives a tool-using turn over the resumed transcript")
    @MainActor
    func resumingWithDifferentToolSetWorks() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "final answer")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // The parent handle never sees any tools.
        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "hi there")
        await parentHandle.sync(parentSession.transcript)

        // Resume with a fresh tool the parent never had.
        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        let childSession = LanguageModelSession(
            model: childHandle, tools: [UppercaseTool()], transcript: restored)
        let response = try await childSession.respond(to: "please uppercase hi")
        #expect(response.content == "final answer")
        await childHandle.sync(childSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let childOwnEvents = try tree.events(forSession: childHandle.state.sessionId)
        #expect(childOwnEvents.map(\.kind) == [.session, .prompt, .toolCalls, .toolOutput, .response])
    }

    // MARK: - Reconstruction over parent plus child

    @Test("TranscriptTree reconstruction over parent plus child yields the full conversation")
    @MainActor
    func reconstructionOverParentAndChildYieldsFullConversation() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let model = StubUnderlyingModel(plainResponseText: "reply", toolResponseText: "tool reply")
        let router = Self.makeRouter(
            container: StubLanguageModelContainer(model: model),
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let parentHandle = profile.standard.makeLanguageModel()
        let parentSession = LanguageModelSession(
            model: parentHandle, tools: [], instructions: "be terse")
        _ = try await parentSession.respond(to: "first prompt")
        await parentHandle.sync(parentSession.transcript)

        let (childHandle, restored) = try profile.standard.makeLanguageModel(
            resuming: parentHandle.state.sessionId)
        let childSession = LanguageModelSession(model: childHandle, tools: [], transcript: restored)
        _ = try await childSession.respond(to: "second prompt")
        await childHandle.sync(childSession.transcript)

        // The parent keeps generating AFTER the resume point. This must never
        // leak into the child's effective conversation: `forkedAtEntryCount`
        // pins the cut point to the parent's entry count AT RESUME TIME, not
        // however much the parent has grown to by the time of reconstruction
        // — the same invariant `RoutedSessionActor.fork`'s own
        // `forkedAtEntryCount` establishes. Without this step, an inflated
        // `forkedAtEntryCount` (an overcount) would be indistinguishable from
        // the correct value, since `Array.prefix(_:)` silently clamps to
        // however much history actually exists.
        _ = try await parentSession.respond(to: "parent continues after resume")
        await parentHandle.sync(parentSession.transcript)

        let routerDirectory = recordingsDir.appendingPathComponent(
            router.id.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let fullConversation = try tree.effectiveEntryEvents(forSession: childHandle.state.sessionId)

        #expect(
            fullConversation.map(\.kind) == [.instructions, .prompt, .response, .prompt, .response])
        #expect(
            fullConversation.map(\.text) == [
                "be terse", "first prompt", "reply", "second prompt", "reply",
            ])
        #expect(!fullConversation.contains { $0.text == "parent continues after resume" })

        // MergedTranscript sees every recorded event across both sessions
        // (parent's 6, after its extra post-resume turn, + child's 3), unlike
        // the tree's truncated/entry-kind-only view — a second, independent
        // confirmation that nothing was lost or duplicated across the resume
        // boundary.
        let merged = try MergedTranscript.merged(under: routerDirectory)
        #expect(merged.count == 9)
    }
}
