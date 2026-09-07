import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 5a: a resolved profile's residency lifecycle — the
/// residency ends when the last reference to the profile is dropped, and the
/// next ``Router/resolve(profile:reporting:)`` gives it back — and the
/// embedding access surface (``RoutedModel/embed(texts:)`` + `dimension`),
/// which writes nothing to the transcript.
///
/// Everything runs against stubs — a stub ``ModelLoader`` with an eviction spy,
/// a stub embedding container, and an ``InMemoryRecorder`` — so the suite needs
/// no network and no GPU. Real embedding vectors and real MLX unload are gated
/// to the milestone 7 integration suite.
@Suite("Profile lifecycle + embedding access")
struct ProfileLifecycleTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container, with no MLX dependency. These
    /// lifecycle tests never generate, so the vended backend always throws.
    private struct StubLLMContainer: LoadedLLMContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
    }

    /// A stand-in for a loaded embedder container that returns fixed-length
    /// vectors, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int

        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Eviction spy

    /// Counts how many containers were evicted through the loader.
    private actor EvictionSpy {
        private(set) var count = 0
        func record() { count += 1 }
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

    /// A ``ModelLoader`` that returns stub containers without download or GPU
    /// work and records every eviction through the injected spy.
    private struct StubModelLoader: ModelLoader {
        let spy: EvictionSpy
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubLLMContainer()
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

        func evict(container: any LoadedModelContainer) async {
            await spy.record()
        }
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
            .appendingPathComponent("ProfileLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs and the given recorder.
    private static func makeRouter(
        spy: EvictionSpy,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(spy: spy, dimension: stubDimension)
        )
    }

    // MARK: - Residency lifecycle

    @Test("dropping the last reference evicts all three models and clears residency")
    @MainActor
    func droppingTheLastReferenceEvictsAllThree() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        var profile: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 0)

        // Nothing but ARC ends the residency: dropping the profile drops its
        // three handles, and with them the shared residency hold.
        profile.dropReference()

        // The next resolve is the drain point — it gives back every dropped
        // residency before it measures the budget — so it both evicts the
        // three models and proves residency is clear by succeeding.
        let reresolved = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 3)
        withExtendedLifetime(reresolved) {}
    }

    @Test("resolving the same profile a second time while the first is resident shares its models, not rejected")
    @MainActor
    func secondResolveOfSameProfileSharesResidentModels() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        // Pooled residency: a second resolve of the identical profile while
        // the first is still resident now succeeds and reuses the already
        // loaded models (dedup), rather than being rejected — this is
        // exactly what task kh01tv2 replaces the old one-active-profile rule
        // with.
        var first: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        var second: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())

        // Dropping the first leaves the second's models loaded (still
        // referenced); only dropping every reference evicts everything. Each
        // resolve is the drain point: it gives back the dropped residencies
        // before it measures the budget, so it is where the count is read.
        first.dropReference()
        var drainer: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 0)

        second.dropReference()
        drainer.dropReference()
        let reresolved = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 3)
        withExtendedLifetime(reresolved) {}
    }

    @Test("a release carrying a stale token does not clobber a newer resident profile")
    @MainActor
    func staleReleaseDoesNotClobberResident() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        var first: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        let staleToken = try #require(first).residencyToken
        first.dropReference()

        // A second, unrelated profile is now resident under a fresh,
        // never-reused token. This resolve is the drain point: it evicts
        // `first`'s three models before it measures the budget, so it reloads
        // from scratch.
        var second: LanguageModelProfile? = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 3)

        // A release carrying the first profile's defunct token must be a
        // no-op: `first`'s pool entry is already gone, so this must neither
        // evict anything further nor touch `second`'s residency.
        await router.release(token: staleToken)
        #expect(await spy.count == 3)

        // `second` still gives its residency back cleanly, evicting its own
        // three models at the next drain point.
        second.dropReference()
        let reresolved = try await router.resolve(
            profile: Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 6)
        withExtendedLifetime(reresolved) {}
    }

    // MARK: - Embedding access

    @Test("embed returns vectors of length dimension from the stub embedder")
    @MainActor
    func embedReturnsDimensionLengthVectors() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        #expect(profile.embedding.dimension == Self.stubDimension)

        let vectors = try await profile.embedding.embed(texts: ["x", "y", "z"])
        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { $0.count == Self.stubDimension })
    }

    @Test("embed records nothing to the transcript and still returns its vectors")
    @MainActor
    func embedRecordsNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let vectors = try await profile.embedding.embed(texts: ["a", "b"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == Self.stubDimension })

        let events = await recorder.events
        #expect(events.isEmpty)
    }
}
