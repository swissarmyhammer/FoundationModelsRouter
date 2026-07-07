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
    /// These resolve tests never generate, so the vended backend always throws.
    private struct StubLLMContainer: LoadedLLMContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(shouldThrow: true)
        }
    }

    /// A stand-in for a loaded embedder container, with no MLX dependency.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 8
        func embed(texts: [String]) async throws -> [[Float]] {
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

    // MARK: - Scripted metadata source

    /// A ``MetadataSource`` whose fetch outcome for a repo is scripted per
    /// call, consumed in order — so a single ``ModelRef`` shared across two
    /// slots (and therefore fetched twice by the router's sizing step, once
    /// per slot) can be driven through a specific success/failure sequence.
    /// A repo with no script, or an exhausted one, falls back to
    /// ``defaultRaw``, so slots unrelated to the scripted candidate(s)
    /// resolve normally with no extra setup.
    private actor ScriptedMetadataSource: MetadataSource {
        /// One scripted fetch outcome.
        enum Outcome {
            case success(RawRepoMetadata)
            case failDirect(RepoMetadataError)
            case failGeneric(URLError)
        }

        private var scripts: [String: [Outcome]]
        private let defaultRaw: RawRepoMetadata

        init(scripts: [String: [Outcome]], defaultRaw: RawRepoMetadata) {
            self.scripts = scripts
            self.defaultRaw = defaultRaw
        }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            guard var queue = scripts[repo], !queue.isEmpty else {
                return defaultRaw
            }
            let outcome = queue.removeFirst()
            scripts[repo] = queue
            switch outcome {
            case .success(let raw):
                return raw
            case .failDirect(let error):
                throw error
            case .failGeneric(let error):
                throw error
            }
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
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            await stubLoad(ref: ref, reporting: reporting, record: { loadedLLMRefs.append($0) }) { StubLLMContainer() }
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            await stubLoad(ref: ref, reporting: reporting, record: { loadedEmbedderRefs.append($0) }) { StubEmbeddingContainer() }
        }

        func preload(container: any LoadedModelContainer) async throws {
            observedPreloadPhases.append(await MainActor.run { progress.phase })
        }

        /// The shared body of both loaders: observe the live phase, record the
        /// ref via `record`, report a single fake byte total, then return the
        /// stub container built by `container`.
        private func stubLoad<C: LoadedModelContainer>(
            ref: ModelRef,
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

        let resolved = try await router.resolve(profile: Self.profile, reporting: progress)

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

        let resolved = try await router.resolve(profile: Self.profile, reporting: progress)

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
            _ = try await router.resolve(profile: Self.profile, reporting: progress)
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
            _ = try await router.resolve(profile: Self.profile, reporting: progress)
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

    // MARK: - Candidate-sizing merge and failure paths

    /// The generation-slot (`standard`/`flash`) margined footprint for
    /// ``rawMetadata`` at the default context: raw `12_097_152` (10 MB weights
    /// + a 2 MB KV cache at context 8192) × 1.2 = `14_516_583`.
    private static let generationSlotMarginedFootprint: Int64 = 14_516_583

    /// The embedding-slot margined footprint for ``rawMetadata``: weights
    /// alone (no KV cache), raw `10_000_000` × 1.2 = `12_000_000` exactly.
    private static let embeddingSlotMarginedFootprint: Int64 = 12_000_000

    @Test(
        """
        sizeCandidates merges a ModelRef shared across slots by keeping the \
        larger successful footprint (preferLarger .success/.success)
        """
    )
    @MainActor
    func mergeKeepsLargerSuccessfulFootprintAcrossSlots() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The same ref is the sole candidate for both `embedding` and
        // `standard`. Sized as an embedder it is only 10 MB (no KV cache);
        // sized as a generation model at the default context it is ~11.5 MB
        // (weights + KV cache). The merge in `sizeCandidates` must keep the
        // larger of the two for *both* slots' fit test.
        let shared: ModelRef = "org/shared-embed-std"
        let profile = ProfileDefinition(
            name: "shared-embed-std",
            description: "one ref is a candidate for both the embedding and standard slots",
            standard: [shared],
            flash: ["org/flash-only"],
            embedding: [shared]
        )

        let progress = ResolutionProgress()
        let source = ScriptedMetadataSource(scripts: [:], defaultRaw: Self.rawMetadata)
        let loader = StubModelLoader(progress: progress)
        // A budget strictly between the embedding-only margined footprint
        // (12_000_000) and the generation-slot margined footprint of the
        // very same raw metadata (14_516_583): the shared candidate fits
        // neither slot if the merge correctly kept the larger figure, but
        // would fit both if it wrongly kept (or fell back to) the smaller
        // embedding-only one.
        let router = Router(
            headroomReserve: 0,
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 13_000_000, recommendedMaxWorkingSetSize: 13_000_000),
            metadataSource: source,
            loader: loader
        )

        var caught: ResolutionFailure?
        do {
            _ = try await router.resolve(profile: profile, reporting: progress)
        } catch let failure as ResolutionFailure {
            caught = failure
        }
        let failure = try #require(caught)

        let embeddingSlot = try #require(failure.slots.first { $0.slot == .embedding })
        let embeddingReport = try #require(embeddingSlot.considered.first { $0.ref == shared })
        #expect(embeddingReport.estimatedFootprintBytes == Self.generationSlotMarginedFootprint)
        #expect(embeddingReport.verdict == .tooLarge)

        let standardSlot = try #require(failure.slots.first { $0.slot == .standard })
        let standardReport = try #require(standardSlot.considered.first { $0.ref == shared })
        #expect(standardReport.estimatedFootprintBytes == Self.generationSlotMarginedFootprint)
        #expect(standardReport.verdict == .tooLarge)
    }

    @Test(
        """
        sizeCandidates merges a ModelRef shared across slots by preferring a \
        later success over an earlier failure (preferLarger .failure/.success)
        """
    )
    @MainActor
    func mergePrefersSuccessOverAnEarlierFailure() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The same ref is the sole candidate for both `standard` and `flash`.
        // Its fetch fails the first time it is sized (whichever slot that
        // is) and succeeds the second — the merge must keep the success so
        // both slots still resolve to it, rather than the failure poisoning
        // the merged entry.
        let heals: ModelRef = "org/heals-after-one-failure"
        let profile = ProfileDefinition(
            name: "heals",
            description: "one ref fails its first fetch, then sizes successfully",
            standard: [heals],
            flash: [heals],
            embedding: ["org/emb-only"]
        )

        let progress = ResolutionProgress()
        let source = ScriptedMetadataSource(
            scripts: [
                heals.repo: [.failDirect(.metadataUnavailable("transient")), .success(Self.rawMetadata)]
            ],
            defaultRaw: Self.rawMetadata
        )
        let loader = StubModelLoader(progress: progress)
        let router = Router(
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: loader
        )

        let resolved = try await router.resolve(profile: profile, reporting: progress)

        #expect(resolved.standard.chosen == heals)
        #expect(resolved.flash.chosen == heals)
    }

    @Test(
        """
        sizeCandidates merges a ModelRef shared across slots by keeping the \
        first failure when every fetch fails (preferLarger .failure/.failure)
        """
    )
    @MainActor
    func mergeKeepsFirstFailureAcrossSlots() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The same ref is the sole candidate for both `standard` and `flash`,
        // and every fetch for it fails. `preferLarger`'s `.failure/.failure`
        // branch keeps `lhs` — the chronologically-first computed result,
        // which (since calls are sequential) is always whichever slot's
        // fetch happens first, regardless of slot iteration order.
        let dualFail: ModelRef = "org/dual-fail"
        let profile = ProfileDefinition(
            name: "dual-fail",
            description: "one ref fails on every slot's fetch",
            standard: [dualFail],
            flash: [dualFail],
            embedding: ["org/emb-only"]
        )

        let progress = ResolutionProgress()
        let source = ScriptedMetadataSource(
            scripts: [
                dualFail.repo: [
                    .failDirect(.metadataUnavailable("first attempt unavailable")),
                    .failDirect(.metadataUnavailable("second attempt unavailable")),
                ]
            ],
            defaultRaw: Self.rawMetadata
        )
        let loader = StubModelLoader(progress: progress)
        let router = Router(
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: loader
        )

        var caught: ResolutionFailure?
        do {
            _ = try await router.resolve(profile: profile, reporting: progress)
        } catch let failure as ResolutionFailure {
            caught = failure
        }
        let failure = try #require(caught)

        let standardSlot = try #require(failure.slots.first { $0.slot == .standard })
        let standardReport = try #require(standardSlot.considered.first { $0.ref == dualFail })
        #expect(standardReport.verdict == .metadataUnavailable("first attempt unavailable"))

        let flashSlot = try #require(failure.slots.first { $0.slot == .flash })
        let flashReport = try #require(flashSlot.considered.first { $0.ref == dualFail })
        #expect(flashReport.verdict == .metadataUnavailable("first attempt unavailable"))
    }

    @Test(
        """
        footprintBytes passes a thrown RepoMetadataError through unchanged and \
        wraps a thrown generic Error into .metadataUnavailable(localizedDescription)
        """
    )
    @MainActor
    func footprintBytesPassesRepoMetadataErrorThroughAndWrapsGenericError() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let direct: ModelRef = "org/direct-repo-metadata-error"
        let generic: ModelRef = "org/generic-error"
        let genericError = URLError(.timedOut)

        let profile = ProfileDefinition(
            name: "sizing-failures",
            description: "one candidate fails with a RepoMetadataError, one with a generic Error",
            standard: [direct, generic],
            flash: ["org/flash-only"],
            embedding: ["org/emb-only"]
        )

        let progress = ResolutionProgress()
        let source = ScriptedMetadataSource(
            scripts: [
                direct.repo: [.failDirect(.metadataUnavailable("direct: boom"))],
                generic.repo: [.failGeneric(genericError)],
            ],
            defaultRaw: Self.rawMetadata
        )
        let loader = StubModelLoader(progress: progress)
        let router = Router(
            cacheDir: dir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: source,
            loader: loader
        )

        var caught: ResolutionFailure?
        do {
            _ = try await router.resolve(profile: profile, reporting: progress)
        } catch let failure as ResolutionFailure {
            caught = failure
        }
        let failure = try #require(caught)
        let standardSlot = try #require(failure.slots.first { $0.slot == .standard })

        // A thrown RepoMetadataError passes through footprintBytes untouched.
        let directReport = try #require(standardSlot.considered.first { $0.ref == direct })
        #expect(directReport.verdict == .metadataUnavailable("direct: boom"))

        // A thrown generic Error is wrapped, carrying its localizedDescription.
        let genericReport = try #require(standardSlot.considered.first { $0.ref == generic })
        #expect(genericReport.verdict == .metadataUnavailable(genericError.localizedDescription))

        // Both candidates are unavailable, not merely too large — the slot
        // has no viable candidate at all.
        #expect(standardSlot.chosen == nil)
    }

    // MARK: - Progress fraction math

    @Test("DownloadProgress.fraction divides downloaded bytes by the known total")
    func downloadProgressFractionDividesKnownTotal() {
        #expect(DownloadProgress(bytesDownloaded: 5, bytesTotal: 10).fraction == 0.5)
    }

    @Test("DownloadProgress.fraction is 0 when the total is unknown, not a divide-by-zero")
    func downloadProgressFractionZeroWhenTotalUnknown() {
        let dp = DownloadProgress(bytesDownloaded: 42, bytesTotal: 0)
        #expect(dp.fraction == 0)
        #expect(dp.fraction.isNaN == false)
    }

    @Test("DownloadProgress.fraction is exactly 1.0 when downloaded equals total")
    func downloadProgressFractionCompleteIsOne() {
        #expect(DownloadProgress(bytesDownloaded: 100, bytesTotal: 100).fraction == 1.0)
    }

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

    // MARK: - Reporter monotonicity (multi-GB downloads)

    /// Flushes the main actor's queue so a ``Router/reporter(slot:progress:)``
    /// tick — which applies its update inside a `Task { @MainActor }` — has
    /// definitely run before the test inspects the observable.
    ///
    /// The reporter enqueues its update job on the main-actor serial executor
    /// when the tick fires; enqueuing one more main-actor job here and awaiting
    /// it drains that earlier job first (serial FIFO), so a single `await`
    /// deterministically observes the tick with no polling or `sleep`.
    @MainActor
    private func flushMainActor() async {
        await Task { @MainActor in }.value
    }

    /// Ascending byte ticks (0 → 2 GB → 5 GB → 8 GB of an 8 GB model) drive the
    /// slot's byte counts to the latest values and make the overall fraction
    /// strictly increase while the slot is `.downloading`.
    @Test("reporter applies ascending byte ticks and the fraction strictly increases")
    @MainActor
    func reporterAscendingBytesMonotonic() async {
        let progress = ResolutionProgress()
        progress.slots[.standard] = SlotProgress(state: .downloading)
        let report = Router.reporter(slot: .standard, progress: progress)

        let total: Int64 = 8 << 30
        let ticks: [Int64] = [0, 2 << 30, 5 << 30, 8 << 30]

        var lastFraction = -1.0
        for bytes in ticks {
            report(DownloadProgress(bytesDownloaded: bytes, bytesTotal: total))
            await flushMainActor()

            let sp = try! #require(progress.slots[.standard])
            #expect(sp.bytesDownloaded == bytes)
            #expect(sp.bytesTotal == total)
            #expect(progress.fraction > lastFraction)
            lastFraction = progress.fraction
        }
        // The final tick reached the full byte total.
        #expect(progress.slots[.standard]?.bytesDownloaded == total)
    }

    /// An out-of-order tick — a lower `bytesDownloaded`, and a total that reverts
    /// to the not-yet-known `0` — must not reduce the slot's byte count, drop its
    /// known total, or lower the overall fraction (monotonic).
    @Test("reporter ignores a regressing tick: bytes, total, and fraction never decrease")
    @MainActor
    func reporterIgnoresRegressingTick() async {
        let progress = ResolutionProgress()
        progress.slots[.standard] = SlotProgress(state: .downloading)
        let report = Router.reporter(slot: .standard, progress: progress)

        let total: Int64 = 8 << 30
        report(DownloadProgress(bytesDownloaded: 5 << 30, bytesTotal: total))
        await flushMainActor()
        let high = try! #require(progress.slots[.standard]).bytesDownloaded
        let highFraction = progress.fraction
        #expect(high == 5 << 30)

        // A regressing tick with a lower byte count and an unknown (0) total.
        report(DownloadProgress(bytesDownloaded: 2 << 30, bytesTotal: 0))
        await flushMainActor()

        let sp = try! #require(progress.slots[.standard])
        #expect(sp.bytesDownloaded == high)
        #expect(sp.bytesTotal == total)
        #expect(progress.fraction == highFraction)
    }

    /// A late tick arriving after the slot has left `.downloading` (now
    /// `.loading`) is ignored — the existing state guard is preserved so a
    /// stale callback cannot clobber a slot the orchestration has advanced.
    @Test("reporter ignores a tick after the slot has left .downloading")
    @MainActor
    func reporterIgnoresLateTickAfterLoading() async {
        let progress = ResolutionProgress()
        progress.slots[.standard] = SlotProgress(
            state: .downloading,
            bytesDownloaded: 5 << 30,
            bytesTotal: 8 << 30
        )
        let report = Router.reporter(slot: .standard, progress: progress)

        // The orchestration advances the slot to loading before a late tick lands.
        progress.slots[.standard]?.state = .loading
        report(DownloadProgress(bytesDownloaded: 8 << 30, bytesTotal: 8 << 30))
        await flushMainActor()

        let sp = try! #require(progress.slots[.standard])
        #expect(sp.state == .loading)
        #expect(sp.bytesDownloaded == 5 << 30)
    }
}
