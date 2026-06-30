import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the ``Router`` actor's async ``Router/resolve(_:reporting:)``
/// orchestration end to end with a stubbed machine probe, metadata source, and
/// model loader — no network, no GPU. The stubs observe the live
/// ``ResolutionProgress`` phase at each call so the test can assert the
/// `sizing → downloading → loading → ready` progression, not just the end state.
@Suite("Resolve orchestration")
struct ResolveTests {
    // MARK: - Stub container handles

    /// A stand-in for a loaded LLM `ModelContainer`, with no MLX dependency.
    /// These resolve tests never generate, so the generation entry points throw.
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

    /// A stand-in for a loaded embedder container, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 8
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0, count: dimension) }
        }
    }

    // MARK: - Stub machine probe

    /// A ``MachineProbe`` returning fixed numbers so the budget is deterministic.
    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    // MARK: - Stub metadata source

    /// A ``MetadataSource`` returning the same canned bytes for every repo and
    /// recording the ``ResolutionProgress`` phase observed at fetch time.
    private actor StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        private let progress: ResolutionProgress
        private(set) var observedPhases: [ResolutionProgress.Phase] = []

        init(raw: RawRepoMetadata, progress: ResolutionProgress) {
            self.raw = raw
            self.progress = progress
        }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            let phase = await MainActor.run { progress.phase }
            observedPhases.append(phase)
            return raw
        }
    }

    // MARK: - Stub model loader

    /// A ``ModelLoader`` that returns stub containers without any download or GPU
    /// work, reports a single fake byte total, and records the
    /// ``ResolutionProgress`` phase observed during load and preload.
    private actor StubModelLoader: ModelLoader {
        private let progress: ResolutionProgress
        private(set) var observedLoadPhases: [ResolutionProgress.Phase] = []
        private(set) var observedPreloadPhases: [ResolutionProgress.Phase] = []
        private(set) var loadedLLMRefs: [ModelRef] = []
        private(set) var loadedEmbedderRefs: [ModelRef] = []

        init(progress: ResolutionProgress) {
            self.progress = progress
        }

        func loadLLM(
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            await stubLoad(ref, reporting: reporting, record: { loadedLLMRefs.append($0) }) { StubLLMContainer() }
        }

        func loadEmbedder(
            _ ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            await stubLoad(ref, reporting: reporting, record: { loadedEmbedderRefs.append($0) }) { StubEmbeddingContainer() }
        }

        func preload(_ container: any LoadedModelContainer) async throws {
            observedPreloadPhases.append(await MainActor.run { progress.phase })
        }

        /// The shared body of both loaders: observe the live phase, record the
        /// ref via `record`, report a single fake byte total, then return the
        /// stub container built by `container`.
        private func stubLoad<C: LoadedModelContainer>(
            _ ref: ModelRef,
            reporting: @escaping @Sendable (DownloadProgress) -> Void,
            record: (ModelRef) -> Void,
            container: () -> C
        ) async -> C {
            observedLoadPhases.append(await MainActor.run { progress.phase })
            record(ref)
            reporting(DownloadProgress(bytesDownloaded: 1_000, bytesTotal: 1_000))
            return container()
        }
    }

    // MARK: - Fixtures

    /// A canned `config.json` with a small attention shape so footprints are tiny.
    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    /// A canned tree listing with a single 10 MB weight shard.
    private static let treeJSON = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// The authored profile resolved by every test: two standard candidates, one
    /// flash candidate, one embedding candidate.
    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a", "org/std-b"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    /// Creates a unique temporary cache directory.
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolveTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Success path

    @Test("resolve selects the joint-fit trio and drives progress to ready")
    @MainActor
    func successResolvesTrioAndDrivesProgress() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = ResolutionProgress()
        let source = StubMetadataSource(raw: Self.rawMetadata, progress: progress)
        let loader = StubModelLoader(progress: progress)
        let recorder = InMemoryRecorder()
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: loader
        )

        let resolved = try await router.resolve(Self.profile, reporting: progress)

        // The profile is populated with the highest-preference candidate per slot.
        #expect(resolved.definitionName == "coding")
        #expect(resolved.standard.chosen == "org/std-a")
        #expect(resolved.flash.chosen == "org/flash-a")
        #expect(resolved.embedding.chosen == "org/emb-a")
        #expect(resolved.standard.slot == .standard)
        #expect(resolved.flash.slot == .flash)
        #expect(resolved.embedding.slot == .embedding)

        // Progress reached ready with a full bar and every slot ready + chosen.
        #expect(progress.phase == .ready)
        #expect(progress.fraction == 1.0)
        for slot in [ModelSlot.standard, .flash, .embedding] {
            let sp = try #require(progress.slots[slot])
            #expect(sp.state == .ready)
            #expect(sp.chosen != nil)
        }

        // The phases were entered in order: sizing (at fetch), downloading (at
        // load), loading (at preload).
        #expect(await source.observedPhases.allSatisfy { $0 == .sizing })
        #expect(await source.observedPhases.isEmpty == false)
        #expect(await loader.observedLoadPhases.allSatisfy { $0 == .downloading })
        #expect(await loader.observedLoadPhases.count == 3)
        #expect(await loader.observedPreloadPhases.allSatisfy { $0 == .loading })
        #expect(await loader.observedPreloadPhases.count == 3)
    }

    @Test("each vended handle carries the Router's id and recorder")
    @MainActor
    func handlesCarryRouterIDAndRecorder() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = ResolutionProgress()
        let source = StubMetadataSource(raw: Self.rawMetadata, progress: progress)
        let loader = StubModelLoader(progress: progress)
        let recorder = InMemoryRecorder()
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: loader
        )

        let resolved = try await router.resolve(Self.profile, reporting: progress)

        #expect(resolved.standard.routerId == router.id)
        #expect(resolved.flash.routerId == router.id)
        #expect(resolved.embedding.routerId == router.id)
        #expect(resolved.standard.recorder as? InMemoryRecorder === recorder)
        #expect(resolved.flash.recorder as? InMemoryRecorder === recorder)
        #expect(resolved.embedding.recorder as? InMemoryRecorder === recorder)
    }

    // MARK: - Failure path

    @Test("an unsatisfiable profile throws ResolutionFailure and sets phase .failed")
    @MainActor
    func unsatisfiableFailsAndThrows() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = ResolutionProgress()
        let source = StubMetadataSource(raw: Self.rawMetadata, progress: progress)
        let loader = StubModelLoader(progress: progress)
        // A tiny working set makes the budget far too small for any candidate.
        let router = Router(
            headroomReserve: 0,
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Tiny", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 1_000),
            metadataSource: source,
            loader: loader
        )

        await #expect(throws: ResolutionFailure.self) {
            _ = try await router.resolve(Self.profile, reporting: progress)
        }

        guard case .failed = progress.phase else {
            Issue.record("expected phase .failed, got \(progress.phase)")
            return
        }
        // The loader was never asked to download anything on the failure path.
        #expect(await loader.observedLoadPhases.isEmpty)
    }

    // MARK: - Identity

    @Test("a passed-in id is retained")
    func passedInIDRetained() {
        let id = ULID.generate()
        let router = Router(id: id)
        #expect(router.id == id)
    }

    @Test("a fresh Router gets a unique id when none is passed")
    func freshRouterGetsUniqueID() {
        let a = Router()
        let b = Router()
        #expect(a.id != b.id)
    }

    // MARK: - Loader failure path

    @Test("a loader failure during download sets phase .failed and rethrows")
    @MainActor
    func loaderFailureSetsPhaseFailed() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = ResolutionProgress()
        let source = StubMetadataSource(raw: Self.rawMetadata, progress: progress)
        // The default UnconfiguredModelLoader throws .notConfigured at load time,
        // so sizing + joint fit succeed but the download step fails.
        let router = Router(
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: UnconfiguredModelLoader()
        )

        await #expect(throws: ModelLoaderError.self) {
            _ = try await router.resolve(Self.profile, reporting: progress)
        }

        guard case .failed = progress.phase else {
            Issue.record("expected phase .failed, got \(progress.phase)")
            return
        }
        // The slot that was mid-download is marked failed, not left dangling.
        let standard = try #require(progress.slots[.standard])
        guard case .failed = standard.state else {
            Issue.record("expected standard slot .failed, got \(standard.state)")
            return
        }
    }

    // MARK: - Progress fraction math

    @Test("SlotProgress.progressFraction reflects state and download bytes")
    func slotProgressFractionMath() {
        #expect(SlotProgress(state: .pending).progressFraction == 0)
        #expect(SlotProgress(state: .sizing).progressFraction == 0)
        #expect(SlotProgress(state: .failed("x")).progressFraction == 0)
        #expect(SlotProgress(state: .downloading, bytesDownloaded: 0, bytesTotal: 100).progressFraction == 0)
        #expect(SlotProgress(state: .downloading, bytesDownloaded: 50, bytesTotal: 100).progressFraction == 0.25)
        #expect(SlotProgress(state: .downloading, bytesDownloaded: 100, bytesTotal: 100).progressFraction == 0.5)
        // An unknown total yields 0 rather than a divide-by-zero.
        #expect(SlotProgress(state: .downloading, bytesDownloaded: 10, bytesTotal: 0).progressFraction == 0)
        #expect(SlotProgress(state: .loading).progressFraction == 0.5)
        #expect(SlotProgress(state: .ready).progressFraction == 1)
    }

    @Test("refreshFraction averages the slots' progress fractions")
    @MainActor
    func refreshFractionAverages() {
        let progress = ResolutionProgress()
        progress.slots = [
            .standard: SlotProgress(state: .ready),
            .flash: SlotProgress(state: .loading),
            .embedding: SlotProgress(state: .downloading, bytesDownloaded: 50, bytesTotal: 100),
        ]
        progress.refreshFraction()
        // (1.0 + 0.5 + 0.25) / 3
        #expect(progress.fraction == (1.0 + 0.5 + 0.25) / 3.0)
    }
}
