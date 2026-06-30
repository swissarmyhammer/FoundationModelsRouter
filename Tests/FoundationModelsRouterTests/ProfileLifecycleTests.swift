import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 5a: a resolved profile's residency lifecycle
/// (``LanguageModelProfile/release()`` + the ``Router``'s one-active-profile
/// rule) and the recorded embedding access surface
/// (``RoutedEmbedder/embed(_:)`` + `dimension`).
///
/// Everything runs against stubs — a stub ``ModelLoader`` with an eviction spy,
/// a stub embedding container, and an ``InMemoryRecorder`` — so the suite needs
/// no network and no GPU. Real embedding vectors and real MLX unload are gated
/// to the milestone 7 integration suite.
@Suite("Profile lifecycle + recorded embedding")
struct ProfileLifecycleTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container, with no MLX dependency. These
    /// lifecycle tests never generate, so the generation entry points throw.
    private struct StubLLMContainer: LoadedLLMContainer {
        func respond(to prompt: String, instructions: String?) async throws -> String {
            throw GenerationError.notWiredForLiveInference
        }

        func streamResponse(
            to prompt: String,
            instructions: String?
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish(throwing: GenerationError.notWiredForLiveInference) }
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
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubLLMContainer()
        }

        func loadEmbedder(
            _ ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(_ container: any LoadedModelContainer) async throws {}

        func evict(_ container: any LoadedModelContainer) async {
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

    @Test("release() evicts all three models and clears residency")
    @MainActor
    func releaseEvictsAllThree() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        #expect(await spy.count == 0)

        await profile.release()
        #expect(await spy.count == 3)

        // Residency is clear: a fresh resolve succeeds.
        _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
    }

    @Test("a second resolve while a profile is resident throws, then succeeds after release")
    @MainActor
    func oneActiveProfileEnforced() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        let first = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        await #expect(throws: RouterError.self) {
            _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        }

        await first.release()

        // After release the slot is free again.
        _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
    }

    @Test("a release carrying a stale token does not clobber a newer resident profile")
    @MainActor
    func staleReleaseDoesNotClobberResident() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)

        let first = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        let staleToken = first.residencyToken
        let staleContainers: [any LoadedModelContainer] = [
            first.standard.container, first.flash.container, first.embedding.container,
        ]
        await first.release()

        // A second profile is now resident under a fresh, never-reused token.
        let second = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        // A release carrying the first profile's defunct token must be a no-op:
        // it must neither clear `second`'s residency nor evict any container.
        let evictionsBefore = await spy.count
        await router.release(token: staleToken, containers: staleContainers)
        #expect(await spy.count == evictionsBefore)

        // `second` is still resident, so a fresh resolve is rejected.
        await #expect(throws: RouterError.self) {
            _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
        }

        // And `second` still releases cleanly, freeing the slot.
        await second.release()
        _ = try await router.resolve(Self.profile, reporting: ResolutionProgress())
    }

    // MARK: - Recorded embedding access

    @Test("embed returns vectors of length dimension from the stub embedder")
    @MainActor
    func embedReturnsDimensionLengthVectors() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let router = Self.makeRouter(spy: spy, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        #expect(profile.embedding.dimension == Self.stubDimension)

        let vectors = try await profile.embedding.embed(["x", "y", "z"])
        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { $0.count == Self.stubDimension })
    }

    @Test("embed emits exactly one embedding event with correct provenance")
    @MainActor
    func embedRecordsOneEmbeddingEvent() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = EvictionSpy()
        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        _ = try await profile.embedding.embed(["a", "b"])

        let events = await recorder.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .embedding)
        #expect(event.routerId == router.id)
        #expect(event.slot == .embedding)
        #expect(event.model == profile.embedding.chosen)
    }

    @Test("embed swallows a forced sink failure and still returns its vectors")
    @MainActor
    func embedSwallowsSinkFailure() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A regular file standing where the recorder's directory should be makes
        // every append's directory-create fail, so the write is swallowed.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let spy = EvictionSpy()
        let recorder: JSONLRecorder = .jsonl(directory: blocker)
        let router = Self.makeRouter(spy: spy, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let vectors = try await profile.embedding.embed(["a", "b"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == Self.stubDimension })

        // The blocking file is untouched: nothing was written through it.
        #expect(try Data(contentsOf: blocker).isEmpty)
    }
}
