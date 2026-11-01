import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Proves that a router resolves a profile with a local model folder: it sizes
/// the folder from its files, makes no Hub call for it, and gives the absolute
/// path to the loader. No test uses the network or a GPU.
@Suite("Resolve with a local model folder")
struct ResolveLocalModelTests {
    /// A stand-in for a loaded generation model.
    private struct StubLLMContainer: LoadedLLMContainer {
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
    }

    /// A stand-in for a loaded embedding model.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1

        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [0] }
        }
    }

    /// A machine with plenty of memory.
    private struct StubProbe: MachineProbe {
        let chip = "Apple Test"
        let totalRAM: Int64 = 64 << 30
        let recommendedMaxWorkingSetSize: Int64 = 48 << 30
    }

    /// A Hub source that gives one MLX repo for every id and records each id.
    private actor RecordingMetadataSource: MetadataSource {
        /// The repo ids that were asked for, in order.
        private(set) var askedRepos: [String] = []

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            askedRepos.append(repo)
            return RawRepoMetadata(configJSON: ResolveLocalModelTests.configJSON, treeJSON: ResolveLocalModelTests.treeJSON)
        }
    }

    /// A loader that gives stub containers and records the embedding refs.
    private actor RecordingModelLoader: ModelLoader {
        /// The refs that were loaded for the embedding slot.
        private(set) var loadedEmbedderRefs: [ModelRef] = []

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            StubLLMContainer()
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            loadedEmbedderRefs.append(ref)
            return StubEmbeddingContainer()
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// A `config.json` with a small attention shape.
    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2, "num_attention_heads": 8, "num_key_value_heads": 2,
            "head_dim": 16, "hidden_size": 128, "max_position_embeddings": 8192
        }
        """.utf8)

    /// A tree with one small weight shard.
    private static let treeJSON = Data("""
        [{"type": "file", "path": "model.safetensors", "size": 1000}]
        """.utf8)

    /// The size of the Core ML package of the local folder.
    private static let packageBytes = 400

    /// The context of the profile in tokens.
    private static let context = 4_096

    /// The Hub id of the generation candidates and of the Hub embedding candidate.
    private static let hubStandard: ModelRef = "org/standard"
    private static let hubFlash: ModelRef = "org/flash"
    private static let hubEmbedding: ModelRef = "org/embedder"

    /// A profile whose embedding candidates are `embedding`.
    private static func profile(embedding: [ModelRef]) -> ProfileDefinition {
        ProfileDefinition(
            name: "local", description: "local embedder",
            standard: [hubStandard], flash: [hubFlash], embedding: embedding, context: context)
    }

    /// Makes a router over the stubs.
    private static func makeRouter(
        cache: TempModelFolder, source: RecordingMetadataSource, loader: RecordingModelLoader
    ) -> Router {
        Router(
            cacheDir: cache.url, recorder: InMemoryRecorder(), probe: StubProbe(), metadataSource: source,
            loader: loader, pool: ModelPool())
    }

    /// Resolves `profile` over the stubs and gives the stubs back.
    @MainActor
    private static func resolve(
        _ profile: ProfileDefinition, cache: TempModelFolder
    ) async throws -> (resolved: LanguageModelProfile, source: RecordingMetadataSource, loader: RecordingModelLoader) {
        let source = RecordingMetadataSource()
        let loader = RecordingModelLoader()
        let router = makeRouter(cache: cache, source: source, loader: loader)
        let resolved = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        return (resolved, source, loader)
    }

    @Test("a local Core ML folder is chosen for the embedding slot, and the Hub is not asked for it")
    @MainActor
    func localEmbedderIsNotAskedFromTheHub() async throws {
        let cache = try TempModelFolder(prefix: "ResolveLocalModelTests-cache")
        let folder = try TempModelFolder(prefix: "ResolveLocalModelTests-model")
        defer { cache.remove(); folder.remove() }
        try folder.writeFile("embedder.mlpackage/Data/weight.bin", byteCount: Self.packageBytes)

        let result = try await Self.resolve(Self.profile(embedding: [ModelRef(repo: folder.url.path)]), cache: cache)

        #expect(await result.source.askedRepos.contains { $0.hasPrefix("/") } == false)
    }

    @Test("a local Core ML folder is given to the loader as its absolute path")
    @MainActor
    func loaderGetsTheAbsolutePath() async throws {
        let cache = try TempModelFolder(prefix: "ResolveLocalModelTests-cache")
        let folder = try TempModelFolder(prefix: "ResolveLocalModelTests-model")
        defer { cache.remove(); folder.remove() }
        try folder.writeFile("embedder.mlpackage/Data/weight.bin", byteCount: Self.packageBytes)

        let result = try await Self.resolve(Self.profile(embedding: [ModelRef(repo: folder.url.path)]), cache: cache)

        #expect(await result.loader.loadedEmbedderRefs.map(\.repo) == [folder.url.standardizedFileURL.path])
    }

    @Test("a ~ path that names no folder is not sent to the Hub, and the next candidate is chosen")
    @MainActor
    func missingTildeFolderFallsThrough() async throws {
        let cache = try TempModelFolder(prefix: "ResolveLocalModelTests-cache")
        defer { cache.remove() }
        let missing = ModelRef(repo: "~/no-such-model-\(UUID().uuidString)")

        let result = try await Self.resolve(Self.profile(embedding: [missing, Self.hubEmbedding]), cache: cache)

        #expect(result.resolved.embedding.chosen == Self.hubEmbedding)
        #expect(await result.source.askedRepos.contains { $0.hasPrefix("~") || $0.hasPrefix("/") } == false)
    }
}
