import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 6: the plan's core "built early and shared" goal — tools
/// take the model a resolved profile vends in their constructors, so many tools
/// reuse a small set of resident models instead of each re-resolving.
///
/// The example tools (``SummarizeTool``, ``EmbedTool``) hold the injected slot
/// handle and drive it (`makeSession`/`respond`, `embed`). These tests prove
/// that constructing tools from the same resolved handle shares the identical
/// resident model — no second load through the loader — that a tool's call flows
/// through the recorded chokepoint, and that constructing tools does not disturb
/// the router's one-active-profile residency.
///
/// Everything runs against stubs — a load-counting stub ``ModelLoader``, a
/// canned LLM container that returns fixed text, a stub embedding container, and
/// an ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("Tool integration: shared-profile constructor pattern")
struct ToolIntegrationTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, with no
    /// MLX dependency.
    private struct CannedLLMContainer: LoadedLLMContainer {
        let text: String

        func respond(to prompt: String, instructions: String?) async throws -> String {
            text
        }

        func streamResponse(
            to prompt: String,
            instructions: String?
        ) -> AsyncThrowingStream<String, Error> {
            let text = text
            return AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    /// A stand-in for a loaded embedder container that returns fixed-length
    /// vectors, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Loader spy

    /// Counts every load and eviction through the loader, keyed by the model
    /// ref, so a test can assert a slot is loaded exactly once at resolve and
    /// never again when tools are constructed from its vended handle.
    private actor LoaderSpy {
        private(set) var llmLoads: [ModelRef: Int] = [:]
        private(set) var embedderLoads: [ModelRef: Int] = [:]
        private(set) var evictions = 0

        func recordLlmLoad(_ ref: ModelRef) { llmLoads[ref, default: 0] += 1 }
        func recordEmbedderLoad(_ ref: ModelRef) { embedderLoads[ref, default: 0] += 1 }
        func recordEviction() { evictions += 1 }

        /// The total number of load calls across both loaders.
        var totalLoads: Int {
            llmLoads.values.reduce(0, +) + embedderLoads.values.reduce(0, +)
        }
    }

    // MARK: - Stubs

    /// A ``MachineProbe`` returning fixed numbers so the budget is deterministic.
    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    /// A ``MetadataSource`` returning the same canned bytes for every repo.
    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns canned containers without download or GPU
    /// work and records every load and eviction through the injected spy.
    private struct StubModelLoader: ModelLoader {
        let spy: LoaderSpy
        let dimension: Int
        let text: String

        func loadLLM(
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            await spy.recordLlmLoad(ref)
            return CannedLLMContainer(text: text)
        }

        func loadEmbedder(
            _ ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            await spy.recordEmbedderLoad(ref)
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(_ container: any LoadedModelContainer) async throws {}

        func evict(_ container: any LoadedModelContainer) async {
            await spy.recordEviction()
        }
    }

    // MARK: - Fixtures

    private static let configJson = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJson = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJson, treeJSON: treeJson)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8
    private static let cannedText = "canned summary"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and the given recorder.
    private static func makeRouter(
        spy: LoaderSpy,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(spy: spy, dimension: stubDimension, text: cannedText)
        )
    }

    // MARK: - Shared resident model

    @Test("two tools built from the same handle share one resident model — no second load for the slot")
    @MainActor
    func twoToolsShareOneResidentModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = LoaderSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        // Resolve loaded each slot exactly once.
        #expect(await spy.llmLoads[profile.flash.chosen] == 1)
        let loadsAfterResolve = await spy.totalLoads

        // Two tools constructed from the same vended handle.
        let toolA = SummarizeTool(model: profile.flash)
        let toolB = SummarizeTool(model: profile.flash)

        // They reference the identical resident model instance…
        #expect(toolA.model === toolB.model)
        #expect(toolA.model === profile.flash)

        // …and constructing them triggered no additional load: the flash slot is
        // still loaded exactly once, and the total load count is unchanged.
        #expect(await spy.llmLoads[profile.flash.chosen] == 1)
        #expect(await spy.totalLoads == loadsAfterResolve)
    }

    // MARK: - Recorded chokepoint

    @Test("a summarize tool's call flows through the recorded generation chokepoint")
    @MainActor
    func summarizeToolCallRecordsATurn() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = LoaderSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let tool = SummarizeTool(model: profile.flash)
        let summary = try await tool.summarize("a long document to condense")
        #expect(summary == Self.cannedText)

        // The generation ran through the recorder-bracketed chokepoint: a
        // first-line `session` meta event then one open + one close event,
        // stamped with the flash slot's provenance.
        let events = await recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.allSatisfy { $0.routerId == router.id })
        #expect(events.allSatisfy { $0.slot == .flash })
        #expect(events.allSatisfy { $0.model == profile.flash.chosen })
    }

    @Test("an embed tool's call flows through the recorded embedding chokepoint")
    @MainActor
    func embedToolCallRecordsAnEvent() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = LoaderSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let tool = EmbedTool(model: profile.embedding)
        let vectors = try await tool.embed(["a", "b"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == Self.stubDimension })

        // The embedding ran through the recorded chokepoint: exactly one
        // embedding event stamped with the embedding slot's provenance.
        let events = await recorder.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .embedding)
        #expect(event.routerId == router.id)
        #expect(event.slot == .embedding)
        #expect(event.model == profile.embedding.chosen)
    }

    // MARK: - Residency unchanged

    @Test("constructing tools does not change the active-profile residency")
    @MainActor
    func constructingToolsDoesNotChangeResidency() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = LoaderSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        // Construct several tools from the resolved handles.
        _ = SummarizeTool(model: profile.standard)
        _ = SummarizeTool(model: profile.flash)
        _ = EmbedTool(model: profile.embedding)

        // Residency is unchanged: one profile is still resident, so a second
        // resolve is rejected.
        await #expect(throws: RouterError.self) {
            _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        }

        // And after releasing the one resident profile the slot frees again.
        await profile.release()
        _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
    }
}
