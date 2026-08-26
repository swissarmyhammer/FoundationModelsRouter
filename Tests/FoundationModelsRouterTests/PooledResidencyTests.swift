import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises pooled model residency (task kh01tv2): a ``Router`` now supports
/// several concurrently resident profiles that share one machine budget and
/// dedupe identical resident model instances keyed on ``ModelRef`` (incl.
/// revision) plus the load-time role/context that changes resident bytes —
/// rather than admitting exactly one resident profile at a time.
///
/// Everything runs against stubs — no network, no GPU — so the suite is fast
/// and deterministic.
@Suite("Pooled model residency")
struct PooledResidencyTests {
    // MARK: - Stub containers

    /// A stand-in generation container that returns a canned response
    /// identifying which ref it was loaded for, so a test can prove two
    /// profiles' sessions really hit the same (or different) resident model.
    private struct StubLLMContainer: LoadedLLMContainer {
        let canned: String
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: canned)
        }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: canned)
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Concurrency-observing container (shared-gate test)

    /// Tracks how many bodies are concurrently inside a suspended `respond`
    /// call, so the shared-model concurrency test can assert non-overlap
    /// without sleeps.
    private actor ConcurrencyObserver {
        private(set) var active = 0
        private(set) var maxActive = 0
        private(set) var entryOrder: [String] = []

        func enter(_ id: String) {
            entryOrder.append(id)
            active += 1
            maxActive = max(maxActive, active)
        }

        func exit() {
            active -= 1
        }
    }

    /// A generation backend that suspends on a release gate while inside
    /// `respond`, so a test can observe whether two concurrent calls
    /// serialize (never overlap) or interleave.
    private final class SuspendingSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let observer: ConcurrencyObserver
        private let releaseGate: AsyncSemaphore

        init(observer: ConcurrencyObserver, releaseGate: AsyncSemaphore) {
            self.observer = observer
            self.releaseGate = releaseGate
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            await observer.enter(prompt)
            await releaseGate.wait()
            await observer.exit()
            return "ok-\(prompt)"
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        func transcriptEntries() -> [Transcript.Entry] { [] }
        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
        func makeFork() -> any LanguageModelSessionBackend { self }
    }

    private struct SuspendingLLMContainer: LoadedLLMContainer {
        let observer: ConcurrencyObserver
        let releaseGate: AsyncSemaphore
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            SuspendingSessionBackend(observer: observer, releaseGate: releaseGate)
        }
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            SuspendingSessionBackend(observer: observer, releaseGate: releaseGate)
        }
    }

    // MARK: - Spies

    /// Counts every load/evict the router routes through the loader, keyed by
    /// the exact ``ModelRef`` (revision-sensitive), so a test can prove
    /// dedup happened (one load for two profiles) or didn't (one load per
    /// distinct ref/revision).
    private actor LoadSpy {
        private(set) var llmLoads: [ModelRef] = []
        private(set) var embedderLoads: [ModelRef] = []
        private(set) var evictions = 0

        func recordLLMLoad(_ ref: ModelRef) { llmLoads.append(ref) }
        func recordEmbedderLoad(_ ref: ModelRef) { embedderLoads.append(ref) }
        func recordEviction() { evictions += 1 }
    }

    // MARK: - Other stubs

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
        let spy: LoadSpy
        let dimension: Int
        /// Optional override so the concurrency test can vend a
        /// ``SuspendingLLMContainer`` instead of the plain ``StubLLMContainer``.
        var llmContainer: (@Sendable (ModelRef) -> any LoadedLLMContainer)?

        /// When set, `loadLLM` for exactly this ref signals `entrySignal`
        /// (proving it has been reached) and then awaits `releaseGate` before
        /// returning — a deterministic suspension window for tests exercising
        /// what can interleave with an in-flight `resolve()`.
        var gatedRef: ModelRef?
        var entrySignal: AsyncSemaphore?
        var releaseGate: AsyncSemaphore?

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            await spy.recordLLMLoad(ref)
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            if ref == gatedRef, let entrySignal, let releaseGate {
                entrySignal.signal()
                await releaseGate.wait()
            }
            if let llmContainer { return llmContainer(ref) }
            return StubLLMContainer(canned: "from-\(ref.stringValue)")
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            await spy.recordEmbedderLoad(ref)
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}

        func evict(container: any LoadedModelContainer) async {
            await spy.recordEviction()
        }
    }

    // MARK: - Fixtures

    /// A 2-layer attention shape with a single 10 MB weight shard — the same
    /// canned config every other suite in this target uses, so footprints
    /// are the same well-understood magnitude
    /// (`generationSlotMarginedFootprint` ≈ 14_516_583 bytes,
    /// `embeddingSlotMarginedFootprint` == 12_000_000 bytes at the default
    /// 8192-token context; see `ResolveTests`).
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

    /// One full trio's margined footprint at the default context: standard +
    /// flash (each ≈14_516_583) + embedding (12_000_000).
    private static let oneTrioFootprint: Int64 = 14_516_583 + 14_516_583 + 12_000_000

    /// Headroom added on top of a whole number of trio footprints when sizing
    /// a test router's simulated RAM, so a budget meant to fit exactly N
    /// trios isn't rejected by an off-by-a-few-bytes rounding difference
    /// between this constant's footprint arithmetic and the joint fit's own.
    private static let headroomBufferBytes: Int64 = 1_000

    /// The `× 1.2` margined KV cache of ONE generation session at the default
    /// 8192-token context for the canned 2-layer config (raw 2_097_152 bytes)
    /// — the extra steady-state cost each generation slot beyond the first
    /// adds on a shared resident model, and exactly what ``JointFit`` charges
    /// a second generation slot naming an already-charged reference.
    private static let sessionKVMarginedBytes: Int64 = 2_516_583

    /// The whole reservation ``JointFit`` makes for a trio whose standard and
    /// flash slots name ONE reference: that reference's weights plus one KV
    /// cache (14_516_583), the second slot's own KV cache
    /// (``sessionKVMarginedBytes``), and the embedding model (12_000_000).
    private static let sharedPairTrioFootprint: Int64 =
        14_516_583 + sessionKVMarginedBytes + 12_000_000

    /// The whole reservation a later profile is charged when it resolves an
    /// already-resident trio again: one session KV cache for each of its two
    /// generation slots — its own new sessions materialize new caches on the
    /// shared containers — and zero for the reused embedder.
    private static let reusedTrioCharge: Int64 = sessionKVMarginedBytes * 2

    /// The whole reservation a later profile is charged when it reuses a
    /// resident trio's generation model and embedder but brings its own flash
    /// model: one session KV cache on the reused generation model
    /// (``sessionKVMarginedBytes``), its own flash model's whole footprint
    /// (14_516_583), and zero for the reused embedder.
    private static let reuseWithOwnFlashCharge: Int64 = sessionKVMarginedBytes + 14_516_583

    /// A working context below ``ProfileDefinition/defaultContext``, for the
    /// profile that names an already-resident repo at a second context: the KV
    /// cache is sized into the container at load time, so the same repo at this
    /// context is a different resident model.
    private static let steppedDownContext = 4096

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PooledResidencyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        spy: LoadSpy,
        recommendedMaxWorkingSetSize: Int64,
        cacheDir: URL,
        llmContainer: (@Sendable (ModelRef) -> any LoadedLLMContainer)? = nil,
        gatedRef: ModelRef? = nil,
        entrySignal: AsyncSemaphore? = nil,
        releaseGate: AsyncSemaphore? = nil
    ) -> Router {
        Router(
            headroomReserve: 0,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(
                chip: "Apple Test",
                totalRAM: recommendedMaxWorkingSetSize,
                recommendedMaxWorkingSetSize: recommendedMaxWorkingSetSize
            ),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(
                spy: spy, dimension: 8, llmContainer: llmContainer,
                gatedRef: gatedRef, entrySignal: entrySignal, releaseGate: releaseGate
            )
        )
    }

    // MARK: - Two profiles sharing a ModelRef → one load, two live sessions, both generate.

    @Test("two profiles naming the same models share one loaded instance each and both generate")
    @MainActor
    func sharedRefsLoadOnceAndBothGenerate() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Fits one trio plus the second profile's reuse charge: the second
        // profile shares the resident containers, but each of its two
        // generation slots still pays for its own session KV cache.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.reusedTrioCharge
                + Self.headroomBufferBytes,
            cacheDir: dir
        )

        let shared = ProfileDefinition(
            name: "shared",
            description: "both sessions want the identical models",
            standard: ["org/std-shared"],
            flash: ["org/flash-shared"],
            embedding: ["org/emb-shared"]
        )

        let first = try await router.resolve(profile: shared, reporting: ResolutionProgress())
        let second = try await router.resolve(profile: shared, reporting: ResolutionProgress())

        // Each ref was downloaded/loaded exactly once, not once per profile.
        #expect(await spy.llmLoads.filter { $0 == "org/std-shared" }.count == 1)
        #expect(await spy.llmLoads.filter { $0 == "org/flash-shared" }.count == 1)
        #expect(await spy.embedderLoads.filter { $0 == "org/emb-shared" }.count == 1)

        // Both profiles' sessions independently generate against the shared model.
        let firstReply = try await first.standard.makeSession(instructions: nil).respond(to: "hi")
        let secondReply = try await second.standard.makeSession(instructions: nil).respond(to: "hi")
        #expect(firstReply == "from-org/std-shared")
        #expect(secondReply == "from-org/std-shared")
    }

    // MARK: - Two profiles with disjoint refs → both resident, total within budget.

    @Test("two profiles with disjoint refs are both resident when the union fits the budget")
    @MainActor
    func disjointRefsBothResidentWithinBudget() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Fits two full disjoint trios comfortably, not three.
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint * 2 + Self.headroomBufferBytes, cacheDir: dir)

        let profileA = ProfileDefinition(
            name: "a", description: "profile A",
            standard: ["org/a-std"], flash: ["org/a-flash"], embedding: ["org/a-emb"]
        )
        let profileB = ProfileDefinition(
            name: "b", description: "profile B",
            standard: ["org/b-std"], flash: ["org/b-flash"], embedding: ["org/b-emb"]
        )

        let resolvedA = try await router.resolve(profile: profileA, reporting: ResolutionProgress())
        let resolvedB = try await router.resolve(profile: profileB, reporting: ResolutionProgress())

        #expect(resolvedA.standard.chosen == "org/a-std")
        #expect(resolvedB.standard.chosen == "org/b-std")

        // Both trios loaded independently: 4 distinct generation loads (2 slots ×
        // 2 profiles), 2 embedder loads.
        #expect(await spy.llmLoads.count == 4)
        #expect(await spy.embedderLoads.count == 2)

        // Each generates independently through its own resident model.
        let replyA = try await resolvedA.standard.makeSession(instructions: nil).respond(to: "hi")
        let replyB = try await resolvedB.standard.makeSession(instructions: nil).respond(to: "hi")
        #expect(replyA == "from-org/a-std")
        #expect(replyB == "from-org/b-std")
    }

    // MARK: - Two profiles whose union exceeds the budget → defined, non-OOM outcome.

    @Test("a second profile whose disjoint union would exceed the budget fails cleanly, not by exhausting memory")
    @MainActor
    func unionExceedingBudgetFailsCleanly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Room for exactly one trio, nothing left for a second, disjoint one.
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.headroomBufferBytes, cacheDir: dir)

        let profileA = ProfileDefinition(
            name: "a", description: "profile A",
            standard: ["org/only-a-std"], flash: ["org/only-a-flash"], embedding: ["org/only-a-emb"]
        )
        let profileB = ProfileDefinition(
            name: "b", description: "profile B, disjoint from A",
            standard: ["org/only-b-std"], flash: ["org/only-b-flash"], embedding: ["org/only-b-emb"]
        )

        let resolvedA = try await router.resolve(profile: profileA, reporting: ResolutionProgress())

        // Nothing is evictable — A is still referenced — so resolving B must
        // fail with a clear, typed error rather than exhaust memory.
        await #expect(throws: ResolutionFailure.self) {
            _ = try await router.resolve(profile: profileB, reporting: ResolutionProgress())
        }

        // A's residency is untouched by B's failed attempt: nothing was
        // evicted, and A can still generate.
        #expect(await spy.evictions == 0)
        let replyA = try await resolvedA.standard.makeSession(instructions: nil).respond(to: "hi")
        #expect(replyA == "from-org/only-a-std")
    }

    // MARK: - Releasing one session keeps a shared model loaded for the other; releasing both unloads it.

    @Test("a shared model stays loaded while either profile references it, and unloads only once both release")
    @MainActor
    func releasingOneProfileKeepsSharedModelLoadedForTheOther() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Fits one trio plus the second profile's two-KV-cache reuse charge.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.reusedTrioCharge
                + Self.headroomBufferBytes,
            cacheDir: dir
        )

        let shared = ProfileDefinition(
            name: "shared", description: "both profiles want the identical models",
            standard: ["org/rc-std"], flash: ["org/rc-flash"], embedding: ["org/rc-emb"]
        )

        let first = try await router.resolve(profile: shared, reporting: ResolutionProgress())
        let second = try await router.resolve(profile: shared, reporting: ResolutionProgress())
        #expect(await spy.evictions == 0)

        await first.release()
        // Still referenced by `second` — nothing evicted yet.
        #expect(await spy.evictions == 0)
        _ = try await second.standard.makeSession(instructions: nil).respond(to: "still alive")

        await second.release()
        // Now unreferenced by anyone: all three models evicted.
        #expect(await spy.evictions == 3)
    }

    // MARK: - Concurrent generation on a shared model serializes on the model's generationGate.

    @Test("concurrent generation from two profiles over the same resident model never overlaps")
    @MainActor
    func concurrentGenerationOnSharedModelSerializes() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let observer = ConcurrencyObserver()
        let releaseGate = AsyncSemaphore(value: 0)
        // Fits one trio plus the second profile's two-KV-cache reuse charge.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.reusedTrioCharge
                + Self.headroomBufferBytes,
            cacheDir: dir,
            llmContainer: { _ in SuspendingLLMContainer(observer: observer, releaseGate: releaseGate) }
        )

        let shared = ProfileDefinition(
            name: "shared", description: "both profiles want the identical standard model",
            standard: ["org/gate-std"], flash: ["org/gate-flash"], embedding: ["org/gate-emb"]
        )

        let first = try await router.resolve(profile: shared, reporting: ResolutionProgress())
        let second = try await router.resolve(profile: shared, reporting: ResolutionProgress())

        async let firstReply: String = first.standard.makeSession(instructions: nil).respond(to: "0")
        async let secondReply: String = second.standard.makeSession(instructions: nil).respond(to: "1")

        // Let both calls actually reach (and suspend inside) the shared model
        // before releasing them, so the gate — not scheduling luck — is what
        // is under test.
        while await observer.active == 0 { await Task.yield() }
        // A second caller must be unable to enter while the first still
        // holds the gate: give it a beat, then confirm it never overlapped.
        for _ in 0..<5 { await Task.yield() }
        #expect(await observer.maxActive == 1)

        releaseGate.signal()
        releaseGate.signal()
        _ = try await (firstReply, secondReply)

        #expect(await observer.maxActive == 1)
        #expect(await observer.entryOrder.count == 2)
    }

    // MARK: - Same-ref-different-revision does not share.

    @Test("the same repo pinned to two different revisions does not share a resident instance")
    @MainActor
    func sameRepoDifferentRevisionDoesNotShare() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint * 2 + Self.headroomBufferBytes, cacheDir: dir)

        let unpinned = ProfileDefinition(
            name: "unpinned", description: "tracks the default revision",
            standard: ["org/rev-repo"], flash: ["org/rev-flash-a"], embedding: ["org/rev-emb-a"]
        )
        let pinned = ProfileDefinition(
            name: "pinned", description: "pinned to a specific revision",
            standard: ["org/rev-repo@rev2"], flash: ["org/rev-flash-b"], embedding: ["org/rev-emb-b"]
        )

        // Both resolved profiles are held for the whole test: an unretained
        // profile is deallocated immediately, and its `deinit` fires an
        // unstructured release `Task` that would race the next resolve.
        let resolvedUnpinned = try await router.resolve(profile: unpinned, reporting: ResolutionProgress())
        let resolvedPinned = try await router.resolve(profile: pinned, reporting: ResolutionProgress())
        withExtendedLifetime((resolvedUnpinned, resolvedPinned)) {}

        // Same repo, different revision: two distinct loads, not a dedup.
        #expect(await spy.llmLoads.filter { $0.repo == "org/rev-repo" }.count == 2)
        #expect(Set(await spy.llmLoads.filter { $0.repo == "org/rev-repo" }).count == 2)
    }

    // MARK: - Same-ref-two-roles does not share.

    @Test("the same repo used as a generation model and as an embedder does not share a resident instance")
    @MainActor
    func sameRepoInTwoRolesDoesNotShare() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // The shared ref is a candidate for two slots, so it is sized under its
        // (larger) generation interpretation in both of them — more than a plain
        // trio costs. Two trios' worth of budget covers that comfortably.
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint * 2 + Self.headroomBufferBytes, cacheDir: dir)

        let dualRole = ProfileDefinition(
            name: "dual-role", description: "one repo serves the standard slot and the embedding slot",
            standard: ["org/role-repo"], flash: ["org/role-flash"], embedding: ["org/role-repo"]
        )

        let resolved = try await router.resolve(profile: dualRole, reporting: ResolutionProgress())

        // Same ref, two roles: one generation load and one embedding load, not
        // one pool entry serving both. The two are not interchangeable — they
        // produce structurally different container types.
        #expect(await spy.llmLoads.filter { $0 == "org/role-repo" }.count == 1)
        #expect(await spy.embedderLoads.filter { $0 == "org/role-repo" }.count == 1)

        // Each handle really holds its own role's container.
        let reply = try await resolved.standard.makeSession(instructions: nil).respond(to: "hi")
        #expect(reply == "from-org/role-repo")
        let vectors = try await resolved.embedding.embed(texts: ["hi"])
        #expect(vectors.count == 1)
    }

    // MARK: - Same-ref-different-context does not share.

    @Test("the same repo resolved at two different working contexts does not share a resident instance")
    @MainActor
    func sameRepoDifferentContextDoesNotShare() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint * 2 + Self.headroomBufferBytes, cacheDir: dir)

        let wide = ProfileDefinition(
            name: "wide", description: "runs the shared repo at the default context",
            standard: ["org/ctx-repo"], flash: ["org/ctx-flash-a"], embedding: ["org/ctx-emb-a"]
        )
        let narrow = ProfileDefinition(
            name: "narrow", description: "runs the identical repo at a smaller context",
            standard: ["org/ctx-repo"], flash: ["org/ctx-flash-b"], embedding: ["org/ctx-emb-b"],
            context: Self.steppedDownContext
        )

        // Both resolved profiles are held for the whole test: an unretained
        // profile is deallocated immediately, and its `deinit` fires an
        // unstructured release `Task` that would race the next resolve.
        let resolvedWide = try await router.resolve(profile: wide, reporting: ResolutionProgress())
        let resolvedNarrow = try await router.resolve(profile: narrow, reporting: ResolutionProgress())
        withExtendedLifetime((resolvedWide, resolvedNarrow)) {}

        // One and the same ref — the loads differ only in the context each
        // container was sized for, so a key that ignored the context would
        // hand the second profile the first's KV cache.
        #expect(await spy.llmLoads.filter { $0 == "org/ctx-repo" }.count == 2)
        #expect(Set(await spy.llmLoads.filter { $0 == "org/ctx-repo" }).count == 1)
    }

    // MARK: - Single-profile callers are unaffected.

    @Test("a single caller resolving, releasing, and resolving again sees the same behavior as before pooling")
    @MainActor
    func singleProfileCallerSequentialUseIsUnaffected() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = Self.makeRouter(spy: spy, recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.headroomBufferBytes, cacheDir: dir)

        let profile = ProfileDefinition(
            name: "solo", description: "one profile, used sequentially",
            standard: ["org/solo-std"], flash: ["org/solo-flash"], embedding: ["org/solo-emb"]
        )

        let first = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        await first.release()
        #expect(await spy.evictions == 3)

        // A fresh resolve of the same profile after release reloads from
        // scratch — nothing lingers in the pool once fully released.
        _ = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        #expect(await spy.llmLoads.filter { $0 == "org/solo-std" }.count == 2)
        #expect(await spy.embedderLoads.filter { $0 == "org/solo-emb" }.count == 2)
    }

    // MARK: - release() cannot race an in-flight resolve()'s pool mutations.

    /// Regression test for a TOCTOU race: `resolve()` prices an
    /// already-pool-resident candidate at its marginal cost up front — zero
    /// for a resident embedder, one session KV cache for a resident
    /// generation model (see `footprintBytes`'s `residentKeys` check) — then
    /// only actually acquires (refcount-bumps) that key later in its
    /// acquisition loop. If a concurrent `release()` were allowed to evict
    /// that same key in between — because `release()` held no lock against
    /// an in-flight `resolve()` — the later acquisition step would find the
    /// key gone, silently reload it, and record it in the pool at the stale
    /// marginal charge the joint fit had already committed to. That corrupts
    /// every future budget computation: the model's weights would count as
    /// free forever after, eroding the "single authority over the budget"
    /// guarantee toward an eventual OOM.
    ///
    /// `poolLock` must therefore guard `release(token:)` too, not just
    /// `resolve()` — this test proves a `release()` that starts while a
    /// `resolve()` is suspended mid-acquisition cannot complete (and thus
    /// cannot evict anything) until that `resolve()` finishes.
    @Test("a release cannot interleave with an in-flight resolve and corrupt pool accounting")
    @MainActor
    func releaseCannotRaceAnInFlightResolveAndCorruptAccounting() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let entrySignal = AsyncSemaphore(value: 0)
        let releaseGate = AsyncSemaphore(value: 0)

        // B's own standard slot is a genuinely new ref, gated so B's resolve
        // suspends mid-acquisition — after pricing (which already priced the
        // shared embedding ref as free) but before B ever reaches that
        // shared embedding slot's own acquisition step.
        let gatedRef: ModelRef = "org/race-b-std"
        let sharedEmbeddingRef: ModelRef = "org/race-shared-emb"

        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.oneTrioFootprint * 2 + Self.headroomBufferBytes,
            cacheDir: dir,
            gatedRef: gatedRef,
            entrySignal: entrySignal,
            releaseGate: releaseGate
        )

        let profileA = ProfileDefinition(
            name: "a", description: "owns the shared embedding model",
            standard: ["org/race-a-std"], flash: ["org/race-a-flash"], embedding: [sharedEmbeddingRef]
        )
        let profileB = ProfileDefinition(
            name: "b", description: "wants the same embedding model; its own standard slot is slow to load",
            standard: [gatedRef], flash: ["org/race-b-flash"], embedding: [sharedEmbeddingRef]
        )

        let resolvedA = try await router.resolve(profile: profileA, reporting: ResolutionProgress())

        let resolveBTask = Task { try await router.resolve(profile: profileB, reporting: ResolutionProgress()) }
        await entrySignal.wait()

        // B is now suspended inside its own standard slot's download, with
        // the shared embedding ref already priced as free but not yet
        // reacquired. Ask to release A — the only current reference on the
        // shared embedding model — concurrently.
        let releaseATask = Task { await resolvedA.release() }

        // Give the release every chance to run if it isn't actually blocked.
        for _ in 0..<20 { await Task.yield() }

        releaseGate.signal()
        let resolvedB = try await resolveBTask.value
        await releaseATask.value

        // The shared embedding model must have been loaded exactly once — a
        // second load means B's acquisition found it evicted mid-flight (the
        // race fired) and silently reloaded it while still charging it as free.
        #expect(await spy.embedderLoads.filter { $0 == sharedEmbeddingRef }.count == 1)

        // A's release, once it finally runs, evicts its own two solo models
        // (standard/flash) outright and gives back one reference on the
        // shared embedding model — which B alone now holds, so it survives.
        #expect(await spy.evictions == 2)

        // B's own reference is genuine: releasing it evicts its own two solo
        // models plus the now-fully-unreferenced shared embedding model — 5
        // distinct keys evicted in total across both profiles' releases.
        await resolvedB.release()
        #expect(await spy.evictions == 5)
    }

    // MARK: - A shared generation pair holds both KV caches against the budget.

    /// Regression test for the accounting gap between ``JointFit`` and the
    /// pool (task pq5w87d): a trio whose standard and flash slots name one
    /// reference shares one pool entry, and that entry must hold the WHOLE
    /// reservation joint fit made for the pair — weights plus TWO KV caches —
    /// not just the first slot's footprint. The budget a later resolve sees
    /// pins the two figures together.
    @Test("a profile naming one ref in both generation slots holds two KV caches against the budget")
    @MainActor
    func sharedGenerationPairHoldsBothKVCachesAgainstTheBudget() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Exactly the shared-pair trio's own reservation plus the rounding buffer.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.sharedPairTrioFootprint + Self.headroomBufferBytes,
            cacheDir: dir
        )

        let pair = ProfileDefinition(
            name: "pair", description: "standard and flash share one reference",
            standard: ["org/pair-repo"], flash: ["org/pair-repo"], embedding: ["org/pair-emb"]
        )
        let resolvedPair = try await router.resolve(profile: pair, reporting: ResolutionProgress())
        // One container serves both generation slots.
        #expect(await spy.llmLoads.filter { $0 == "org/pair-repo" }.count == 1)

        // A disjoint second profile cannot fit beside the pair trio, and the
        // budget its failure reports is the host budget minus everything the
        // pair trio reserved — including the second slot's KV cache.
        let disjoint = ProfileDefinition(
            name: "disjoint", description: "cannot fit beside the pair trio",
            standard: ["org/pin-std"], flash: ["org/pin-flash"], embedding: ["org/pin-emb"]
        )
        do {
            _ = try await router.resolve(profile: disjoint, reporting: ResolutionProgress())
            Issue.record("the disjoint profile must not fit beside the pair trio")
        } catch let failure as ResolutionFailure {
            #expect(failure.budgetBytes == Self.headroomBufferBytes)
        }
        withExtendedLifetime(resolvedPair) {}
    }

    // MARK: - Releasing one holder of a shared key gives back only its own share.

    /// The release half of the same accounting (task pq5w87d): a second
    /// profile reusing a resident shared pair charges one session KV cache
    /// for each of its two generation slots, and releasing it gives back
    /// exactly that share — never the first profile's still-live reservation.
    @Test("releasing one of two profiles on a shared generation pair gives back only its own share")
    @MainActor
    func releasingOneHolderOfSharedPairGivesBackOnlyItsShare() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Fits the pair trio, plus the reusing profile's two extra KV caches.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.sharedPairTrioFootprint
                + Self.reusedTrioCharge + Self.headroomBufferBytes,
            cacheDir: dir
        )

        let pair = ProfileDefinition(
            name: "pair", description: "standard and flash share one reference",
            standard: ["org/share-repo"], flash: ["org/share-repo"], embedding: ["org/share-emb"]
        )
        let holder = try await router.resolve(profile: pair, reporting: ResolutionProgress())
        // The same trio again: the containers are shared, and each of its
        // two generation slots is charged its own session KV cache.
        let reuser = try await router.resolve(profile: pair, reporting: ResolutionProgress())

        await reuser.release()
        // The first profile still references everything — nothing is evicted,
        // and only the reuser's own two KV shares came back.
        #expect(await spy.evictions == 0)

        // Pin the released share through the budget a failing resolve sees:
        // the pool still holds the first profile's whole pair reservation.
        let disjoint = ProfileDefinition(
            name: "disjoint", description: "cannot fit beside the pair trio",
            standard: ["org/share-pin-std"], flash: ["org/share-pin-flash"],
            embedding: ["org/share-pin-emb"]
        )
        do {
            _ = try await router.resolve(profile: disjoint, reporting: ResolutionProgress())
            Issue.record("the disjoint profile must not fit beside the pair trio")
        } catch let failure as ResolutionFailure {
            #expect(
                failure.budgetBytes == Self.reusedTrioCharge + Self.headroomBufferBytes
            )
        }
        withExtendedLifetime(holder) {}
    }

    // MARK: - A later resolve reusing a resident generation model is charged its own KV cache.

    /// Regression test for the residual pricing gap after task pq5w87d (task
    /// 4pbv8b9): a later resolve that names an already-resident GENERATION
    /// model must be charged one session KV cache for it — its own new
    /// sessions materialize new caches on the shared container — while a
    /// reused EMBEDDER stays free (an embedder carries no KV term). The
    /// budget a failing third resolve sees pins both charges.
    @Test("a later resolve reusing a resident generation model is charged one session KV cache, and a reused embedder stays free")
    @MainActor
    func reusingResidentGenerationModelChargesOneSessionKVCache() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        // Exactly A's trio, B's own flash model, and B's one KV cache on A's
        // reused generation model — and nothing for B's reused embedder.
        let router = Self.makeRouter(
            spy: spy,
            recommendedMaxWorkingSetSize: Self.oneTrioFootprint + Self.reuseWithOwnFlashCharge
                + Self.headroomBufferBytes,
            cacheDir: dir
        )

        let profileA = ProfileDefinition(
            name: "a", description: "owns the models B will reuse",
            standard: ["org/reuse-std"], flash: ["org/reuse-flash"], embedding: ["org/reuse-emb"]
        )
        let profileB = ProfileDefinition(
            name: "b", description: "reuses A's generation model and embedder, brings its own flash",
            standard: ["org/reuse-std"], flash: ["org/reuse-b-flash"], embedding: ["org/reuse-emb"]
        )

        let resolvedA = try await router.resolve(profile: profileA, reporting: ResolutionProgress())
        let resolvedB = try await router.resolve(profile: profileB, reporting: ResolutionProgress())

        // The reused models were loaded exactly once — B shares A's containers.
        #expect(await spy.llmLoads.filter { $0 == "org/reuse-std" }.count == 1)
        #expect(await spy.embedderLoads.filter { $0 == "org/reuse-emb" }.count == 1)

        // Pin the pool's holdings through the budget a failing third resolve
        // sees: everything is spoken for except the rounding buffer. A zero
        // price on B's reused generation model would leave one whole KV cache
        // of budget here instead.
        let disjoint = ProfileDefinition(
            name: "disjoint", description: "cannot fit beside A and B",
            standard: ["org/reuse-pin-std"], flash: ["org/reuse-pin-flash"],
            embedding: ["org/reuse-pin-emb"]
        )
        do {
            _ = try await router.resolve(profile: disjoint, reporting: ResolutionProgress())
            Issue.record("the disjoint profile must not fit beside A and B")
        } catch let failure as ResolutionFailure {
            #expect(failure.budgetBytes == Self.headroomBufferBytes)
        }
        withExtendedLifetime((resolvedA, resolvedB)) {}
    }
}
