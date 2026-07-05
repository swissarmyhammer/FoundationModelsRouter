import Foundation
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 9: the ``RoutedSession/fork(workingDirectory:)`` primitive
/// over the KV cache plus the two ``AsyncSemaphore``-backed concurrency gates.
///
/// Everything runs against stubs with no network and no GPU:
/// - a ``CacheCensus`` (a ``Mutex``-guarded, *synchronous* counter) and a
///   ``SpyKVCache`` that records `copy()` invocations and cache frees on release,
///   so the copy-on-fork and KV-free-on-release contracts are observed exactly;
/// - an ``InstrumentedLLMContainer`` whose `respond` can be parked on a
///   test-controlled release gate, so the per-model serial gate's non-overlap and
///   FIFO order are made deterministic through the semaphore's `waiterCount`
///   observability rather than sleeps.
///
/// Real prefix reuse (no recompute) and real MLX cache copy are gated to the
/// milestone 7 integration suite; here the abstraction is asserted through the
/// spy.
@Suite("Session fork + per-model concurrency gates")
struct ForkConcurrencyTests {
    // MARK: - Cache census + spy

    /// A synchronous, thread-safe census of cache births, copies, and frees.
    ///
    /// Updated from ``SpyKVCache``'s `init`/`copy()`/`deinit` under a ``Mutex`` so
    /// counts are exact and race-free without an `await` — deterministic even from
    /// a `deinit`. `liveForks`/`maxLiveForks` track only *fork* caches (born from
    /// `copy()`), which is what the fork-admission bound is asserted against.
    private final class CacheCensus: Sendable {
        struct Counts {
            var births = 0
            var copies = 0
            var frees = 0
            var forkFrees = 0
            var liveForks = 0
            var maxLiveForks = 0
        }

        let state = Mutex(Counts())

        /// Records a cache coming into existence; a fork cache also bumps the live
        /// fork high-water mark.
        func birth(isFork: Bool) {
            state.withLock {
                $0.births += 1
                if isFork {
                    $0.liveForks += 1
                    $0.maxLiveForks = max($0.maxLiveForks, $0.liveForks)
                }
            }
        }

        /// Records a `copy()` call — one fork cache produced.
        func copyCall() {
            state.withLock { $0.copies += 1 }
        }

        /// Records a cache being freed; a fork cache also decrements the live count.
        func free(isFork: Bool) {
            state.withLock {
                $0.frees += 1
                if isFork {
                    $0.forkFrees += 1
                    $0.liveForks -= 1
                }
            }
        }

        var copies: Int { state.withLock { $0.copies } }
        var frees: Int { state.withLock { $0.frees } }
        var forkFrees: Int { state.withLock { $0.forkFrees } }
        var liveForks: Int { state.withLock { $0.liveForks } }
        var maxLiveForks: Int { state.withLock { $0.maxLiveForks } }
    }

    /// A stand-in for a session KV cache that records its lifecycle into a
    /// ``CacheCensus`` — no MLX. `copy()` is the fork seam; a copied cache is a
    /// fork cache. Its `deinit` records the free synchronously, so dropping a
    /// session's cache is observed the instant ARC reclaims it.
    private final class SpyKVCache: SessionKVCache {
        let census: CacheCensus
        let isFork: Bool

        init(census: CacheCensus, isFork: Bool) {
            self.census = census
            self.isFork = isFork
            census.birth(isFork: isFork)
        }

        func copy() -> any SessionKVCache {
            census.copyCall()
            return SpyKVCache(census: census, isFork: true)
        }

        deinit {
            census.free(isFork: isFork)
        }
    }

    // MARK: - Serial-gate observability

    /// Tracks the order `respond` bodies enter the model and the peak concurrency,
    /// so the serial gate's non-overlap and FIFO order can be asserted.
    private actor SerialObserver {
        private(set) var entryOrder: [Int] = []
        private(set) var active = 0
        private(set) var maxActive = 0

        func enter(_ id: Int) {
            entryOrder.append(id)
            active += 1
            maxActive = max(maxActive, active)
        }

        func exit() {
            active -= 1
        }
    }

    /// Records the grammar a guided `respond` was constrained with, proving a
    /// fork's inherited grammar still reaches the guided decode entry point.
    private actor GuidedProbe {
        private(set) var grammars: [Grammar] = []

        func record(_ grammar: Grammar) {
            grammars.append(grammar)
        }
    }

    // MARK: - Stub container

    /// A ``LoadedLLMContainer`` that vends ``SpyKVCache`` caches and, when wired
    /// with a serial observer + release gate, parks each `respond` until the test
    /// releases it — so concurrency is observed deterministically. No MLX.
    private struct InstrumentedLLMContainer: LoadedLLMContainer {
        let census: CacheCensus
        let observer: SerialObserver?
        let releaseGate: AsyncSemaphore?
        let guidedProbe: GuidedProbe?

        func makeCache() -> any SessionKVCache {
            SpyKVCache(census: census, isFork: false)
        }

        func respond(to prompt: String, instructions: String?, maxTokens: Int?) async throws -> String {
            if let observer, let releaseGate {
                let id = Int(prompt) ?? -1
                await observer.enter(id)
                await releaseGate.wait()
                await observer.exit()
                return "ok-\(id)"
            }
            return "ok"
        }

        func streamResponse(
            to prompt: String,
            instructions: String?,
            maxTokens: Int?
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        func respond(
            to prompt: String,
            instructions: String?,
            following grammar: Grammar,
            maxTokens: Int?
        ) async throws -> String {
            try grammar.validateForXGrammar()
            if let guidedProbe { await guidedProbe.record(grammar) }
            return "guided-ok"
        }
    }

    /// A stub embedder container — never exercised here, present only so the
    /// profile resolves. No MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns the shared instrumented container for both
    /// generation slots (so forks of one model share one container) and stub
    /// embedders. No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let census: CacheCensus
        let observer: SerialObserver?
        let releaseGate: AsyncSemaphore?
        let guidedProbe: GuidedProbe?
        let dimension: Int

        func loadLLM(
            _ ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return InstrumentedLLMContainer(
                census: census,
                observer: observer,
                releaseGate: releaseGate,
                guidedProbe: guidedProbe
            )
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
            .appendingPathComponent("ForkConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader.
    private static func makeRouter(
        census: CacheCensus,
        cacheDir: URL,
        maxConcurrentForks: Int = 4,
        observer: SerialObserver? = nil,
        releaseGate: AsyncSemaphore? = nil,
        guidedProbe: GuidedProbe? = nil
    ) -> Router {
        Router(
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(
                census: census,
                observer: observer,
                releaseGate: releaseGate,
                guidedProbe: guidedProbe,
                dimension: stubDimension
            )
        )
    }

    /// Spins cooperatively until `condition` holds or a bounded number of yields
    /// elapse, so a deinit-driven or scheduler-ordered state change is observed
    /// without a fixed sleep.
    private static func spin(
        until condition: @Sendable () async -> Bool
    ) async {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Copy-on-fork + parentId

    @Test("fork copies the parent's KV cache and sets parentId to the parent's id")
    @MainActor
    func forkCopiesCacheAndSetsParentId() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let census = CacheCensus()
        let router = Self.makeRouter(census: census, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let parent = profile.standard.makeSession()
        #expect(parent.parentId == nil)

        let child = try await parent.fork(workingDirectory: nil)

        // The child's cache began as a copy of the parent's prefix.
        #expect(census.copies == 1)
        // The child nests under the parent.
        #expect(child.parentId == parent.id)
        #expect(child.id != parent.id)
        // The child inherits the router recording root and profile.
        #expect(child.routerId == parent.routerId)
        #expect(child.profile === parent.profile)

        _ = parent
        _ = child
    }

    // MARK: - KV free on fork release

    @Test("releasing a fork frees its KV cache; the parent's cache is unaffected")
    @MainActor
    func releasingForkFreesItsCacheOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let census = CacheCensus()
        let router = Self.makeRouter(census: census, cacheDir: dir)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let parent = profile.standard.makeSession()
        var child: RoutedSession? = try await parent.fork(workingDirectory: nil)
        #expect(census.copies == 1)
        #expect(census.frees == 0)
        _ = child

        // Dropping the fork frees exactly its (fork) cache.
        child = nil
        await Self.spin(until: { census.forkFrees == 1 })
        #expect(census.forkFrees == 1)
        #expect(census.frees == 1)
        #expect(census.liveForks == 0)

        // The parent's cache is untouched: still generating and not freed.
        let text = try await parent.respond(to: "hi")
        #expect(text == "ok")
        #expect(census.frees == 1)

        _ = parent
    }

    // MARK: - Grammar inheritance on a guided-session fork

    @Test("a guided session's fork inherits the grammar and still constrains output")
    @MainActor
    func guidedForkInheritsGrammar() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let census = CacheCensus()
        let guidedProbe = GuidedProbe()
        let router = Self.makeRouter(census: census, cacheDir: dir, guidedProbe: guidedProbe)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let grammar = Grammar.jsonSchema(#"{"type":"object"}"#)
        let parent = profile.standard.makeGuidedSession(grammar)
        let child = try await parent.fork(workingDirectory: nil)

        #expect(child.grammar == grammar)

        // The fork's respond funnels through the guided (grammar-constrained)
        // entry point with the inherited grammar.
        let text = try await child.respond(to: "x")
        #expect(text == "guided-ok")
        #expect(await guidedProbe.grammars == [grammar])

        _ = parent
    }

    // MARK: - Per-model serial gate

    @Test("concurrent respond() on one model never overlap and run FIFO")
    @MainActor
    func serialGateSerializesAndIsFIFO() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let census = CacheCensus()
        let observer = SerialObserver()
        // Bodies park here; a permit per call is released once the test has
        // established the FIFO arrival order.
        let releaseGate = AsyncSemaphore(value: 0)
        let router = Self.makeRouter(
            census: census,
            cacheDir: dir,
            maxConcurrentForks: 16,
            observer: observer,
            releaseGate: releaseGate
        )
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        // Four callers over the SAME model: a root session and three forks. They
        // share the model's serial gate, so their respond calls must serialize.
        let root = profile.standard.makeSession()
        let fork1 = try await root.fork(workingDirectory: nil)
        let fork2 = try await root.fork(workingDirectory: nil)
        let fork3 = try await root.fork(workingDirectory: nil)
        let callers: [RoutedSession] = [root, fork1, fork2, fork3]

        let serialGate = profile.standard.serialGate

        // Launch call 0; it takes the only serial permit and parks in respond.
        let task0 = Task { try await callers[0].respond(to: "0") }
        await Self.spin(until: { serialGate.availablePermits == 0 })
        await Self.spin(until: { await observer.entryOrder == [0] })

        // Launch calls 1, 2, 3 one at a time, each only after the previous has
        // actually parked on the serial gate — establishing a deterministic FIFO
        // arrival order without sleeping.
        let task1 = Task { try await callers[1].respond(to: "1") }
        await Self.spin(until: { serialGate.waiterCount == 1 })
        let task2 = Task { try await callers[2].respond(to: "2") }
        await Self.spin(until: { serialGate.waiterCount == 2 })
        let task3 = Task { try await callers[3].respond(to: "3") }
        await Self.spin(until: { serialGate.waiterCount == 3 })

        // Only one body has entered so far — the gate held the rest out.
        #expect(await observer.entryOrder == [0])
        #expect(await observer.maxActive == 1)

        // Release the chain; FIFO must admit them 1, 2, 3 in turn.
        for _ in 0..<4 { releaseGate.signal() }

        _ = try await task0.value
        _ = try await task1.value
        _ = try await task2.value
        _ = try await task3.value

        #expect(await observer.entryOrder == [0, 1, 2, 3])
        #expect(await observer.maxActive == 1)

        _ = callers
    }

    // MARK: - Fork admission gate

    @Test("at most maxConcurrentForks forks run concurrently; the next fork awaits a release")
    @MainActor
    func forkAdmissionBoundsConcurrentForks() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let census = CacheCensus()
        let router = Self.makeRouter(census: census, cacheDir: dir, maxConcurrentForks: 2)
        let profile = try await router.resolve(Self.profile, reporting: ResolutionProgress())

        let admissionGate = profile.standard.forkAdmissionGate
        let root = profile.standard.makeSession()

        // Two forks fit the admission ceiling and are admitted immediately.
        var forkA: RoutedSession? = try await root.fork(workingDirectory: nil)
        let forkB: RoutedSession? = try await root.fork(workingDirectory: nil)
        #expect(census.liveForks == 2)
        #expect(census.maxLiveForks == 2)
        #expect(admissionGate.availablePermits == 0)
        _ = forkA
        _ = forkB

        // A third fork must await a free admission slot.
        let thirdTask = Task { try await root.fork(workingDirectory: nil) }
        await Self.spin(until: { admissionGate.waiterCount == 1 })
        #expect(census.liveForks == 2)
        #expect(census.maxLiveForks == 2)

        // Releasing one fork frees its slot; the waiter is admitted. (The ceiling
        // was never exceeded while all three were requested: the parked-state
        // assertions above — two admitted, the third blocked on the gate — are the
        // robust bound evidence; a post-release high-water check would race the
        // freed fork's teardown against the waiter's admission.)
        forkA = nil
        let third = try await thirdTask.value
        #expect(census.forkFrees == 1)
        #expect(census.liveForks == 2)

        _ = forkB
        _ = third
        _ = root
    }
}
