import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 9: the ``RoutedSession/fork(workingDirectory:)`` primitive
/// over the persistent ``LanguageModelSessionBackend`` plus the two
/// ``AsyncSemaphore``-backed concurrency gates.
///
/// Everything runs against stubs with no network and no GPU:
/// - a ``TrackingSessionBackend`` that records call count and prompt history
///   like the shared ``StubSessionBackend``, so a fork's ``makeFork()``-seeded
///   transcript inheritance and independent divergence are observed exactly;
/// - the same backend, when wired with a test-controlled ``SerialObserver`` +
///   release gate, can park `respond` on it, so the per-model serial gate's
///   non-overlap and FIFO order are made deterministic through the semaphore's
///   `waiterCount` observability rather than sleeps.
///
/// Real prefix reuse (no recompute) is gated to the milestone 7 integration
/// suite; here the abstraction is asserted through the stub.
@Suite("Session fork + per-model concurrency gates")
struct ForkConcurrencyTests {
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

    // MARK: - Stub container + backend

    /// A trackable ``LanguageModelSessionBackend`` for this suite: like the
    /// shared ``StubSessionBackend``, it records ``callCount``/``receivedPrompts``
    /// and seeds a fork's history from a copy of its own at fork time — but it
    /// additionally supports parking a call on a test-controlled
    /// ``SerialObserver`` + release gate, and recording the grammar a guided
    /// call was constrained with into a ``GuidedProbe``, neither of which the
    /// other stub-container files in this target need. ``makeFork()``
    /// propagates the same wiring to the child, so a fork of an
    /// observer/gate-wired backend still parks the same way and a fork of a
    /// guided-probe-wired backend still records into the same probe —
    /// mirroring how a fork shares its parent's underlying model.
    private final class TrackingSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var receivedPrompts: [String]
        private(set) var lastFork: TrackingSessionBackend?

        private let observer: SerialObserver?
        private let releaseGate: AsyncSemaphore?
        private let guidedProbe: GuidedProbe?

        init(
            observer: SerialObserver? = nil,
            releaseGate: AsyncSemaphore? = nil,
            guidedProbe: GuidedProbe? = nil,
            receivedPrompts: [String] = []
        ) {
            self.observer = observer
            self.releaseGate = releaseGate
            self.guidedProbe = guidedProbe
            self.receivedPrompts = receivedPrompts
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            callCount += 1
            receivedPrompts.append(prompt)
            if let observer, let releaseGate {
                let id = Int(prompt) ?? -1
                await observer.enter(id)
                await releaseGate.wait()
                await observer.exit()
                return "ok-\(id)"
            }
            return "ok"
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            callCount += 1
            receivedPrompts.append(prompt)
            return AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            callCount += 1
            receivedPrompts.append(prompt)
            try grammar.validateForXGrammar()
            if let guidedProbe { await guidedProbe.record(grammar) }
            return "guided-ok"
        }

        /// No synthetic transcript is tracked here — this suite exercises
        /// call-count/prompt-history/serial-gate/admission-gate behavior, not
        /// transcript accumulation, so there is nothing meaningful to report.
        func transcriptEntries() -> [Transcript.Entry] {
            []
        }

        /// Returns a new backend sharing this one's observer/gate/probe wiring
        /// and pre-seeded with a copy of ``receivedPrompts`` as of this call,
        /// and records the child so a test holding this (parent) backend can
        /// reach it via ``lastFork``.
        func makeFork() -> any LanguageModelSessionBackend {
            let fork = TrackingSessionBackend(
                observer: observer,
                releaseGate: releaseGate,
                guidedProbe: guidedProbe,
                receivedPrompts: receivedPrompts
            )
            lastFork = fork
            return fork
        }
    }

    /// A ``LoadedLLMContainer`` that vends ``TrackingSessionBackend``s wired
    /// with this suite's optional observer/release-gate/guided-probe, and
    /// tracks the most recently manufactured one so a test can assert on its
    /// call history directly. No MLX.
    private final class InstrumentedLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private let observer: SerialObserver?
        private let releaseGate: AsyncSemaphore?
        private let guidedProbe: GuidedProbe?
        private(set) var lastBackend: TrackingSessionBackend?

        init(observer: SerialObserver? = nil, releaseGate: AsyncSemaphore? = nil, guidedProbe: GuidedProbe? = nil) {
            self.observer = observer
            self.releaseGate = releaseGate
            self.guidedProbe = guidedProbe
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = TrackingSessionBackend(observer: observer, releaseGate: releaseGate, guidedProbe: guidedProbe)
            lastBackend = backend
            return backend
        }

        /// Mirrors ``makeSession(instructions:)``'s observer/gate/probe wiring
        /// and ``lastBackend`` tracking invariant instead of the shared plain
        /// default. `TrackingSessionBackend` never models a synthetic
        /// transcript (its ``TrackingSessionBackend/transcriptEntries()``
        /// always reports empty, by design — this suite exercises
        /// call-count/prompt-history/serial-gate behavior, not transcript
        /// accumulation), so `transcript`'s entries have nothing to seed; only
        /// the tracking invariant itself needs to be preserved here.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let backend = TrackingSessionBackend(observer: observer, releaseGate: releaseGate, guidedProbe: guidedProbe)
            lastBackend = backend
            return backend
        }
    }

    /// A stub embedder container — never exercised here, present only so the
    /// profile resolves. No MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
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

    /// A ``ModelLoader`` that returns the identical, test-supplied
    /// ``InstrumentedLLMContainer`` instance for every generation slot (so
    /// forks of one model share one container, and the test that constructed
    /// the container keeps a live handle onto ``InstrumentedLLMContainer/lastBackend``)
    /// and stub embedders. No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let container: InstrumentedLLMContainer
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
            .appendingPathComponent("ForkConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for
    /// every generation slot.
    private static func makeRouter(
        container: InstrumentedLLMContainer,
        cacheDir: URL,
        maxConcurrentForks: Int = 4
    ) -> Router {
        Router(
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
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

    // MARK: - Fork seeds the child's backend from the parent + parentId

    @Test("fork seeds the child's backend from the parent's prompt history and sets parentId to the parent's id")
    @MainActor
    func forkSeedsBackendFromParentAndSetsParentId() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = InstrumentedLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let parent = profile.standard.makeSession()
        #expect(parent.parentId == nil)
        _ = try await parent.respond(to: "hello")

        let parentBackend = try #require(container.lastBackend)
        #expect(parentBackend.callCount == 1)
        #expect(parentBackend.receivedPrompts == ["hello"])

        let child = try await parent.fork(workingDirectory: nil)

        // The fork's backend is produced via makeFork(), pre-seeded with a copy
        // of the parent's prompt history as of fork time — the stand-in for
        // KV-cache copy-on-fork now that generation runs through a persistent
        // backend rather than a per-call container.
        let childBackend = try #require(parentBackend.lastFork)
        #expect(childBackend.receivedPrompts == parentBackend.receivedPrompts)
        #expect(childBackend.callCount == 0)

        // The child nests under the parent.
        #expect(child.parentId == parent.id)
        #expect(child.id != parent.id)
        // The child inherits the router recording root and profile.
        #expect(child.routerId == parent.routerId)
        #expect(child.profile === parent.profile)

        _ = parent
        _ = child
    }

    // MARK: - Fork diverges independently after fork time

    @Test("a fork's backend diverges independently from its parent's after fork time")
    @MainActor
    func forkedBackendDivergesIndependently() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = InstrumentedLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let parent = profile.standard.makeSession()
        let child = try await parent.fork(workingDirectory: nil)
        let parentBackend = try #require(container.lastBackend)
        let childBackend = try #require(parentBackend.lastFork)

        // A turn on the child does not retroactively appear in the parent's
        // history…
        let childText = try await child.respond(to: "child turn")
        #expect(childText == "ok")
        #expect(childBackend.receivedPrompts == ["child turn"])
        #expect(parentBackend.receivedPrompts.isEmpty)

        // …and a further parent turn is independent of the (now-diverged) child.
        let parentText = try await parent.respond(to: "parent turn")
        #expect(parentText == "ok")
        #expect(parentBackend.receivedPrompts == ["parent turn"])
        #expect(childBackend.receivedPrompts == ["child turn"])
    }

    // MARK: - Grammar inheritance on a guided-session fork

    @Test("a guided session's fork inherits the grammar and still constrains output")
    @MainActor
    func guidedForkInheritsGrammar() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guidedProbe = GuidedProbe()
        let container = InstrumentedLLMContainer(guidedProbe: guidedProbe)
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let grammar = Grammar.jsonSchema(#"{"type":"object"}"#)
        let parent = profile.standard.makeGuidedSession(grammar: grammar)
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

        let observer = SerialObserver()
        // Bodies park here; a permit per call is released once the test has
        // established the FIFO arrival order.
        let releaseGate = AsyncSemaphore(value: 0)
        let container = InstrumentedLLMContainer(observer: observer, releaseGate: releaseGate)
        let router = Self.makeRouter(
            container: container,
            cacheDir: dir,
            maxConcurrentForks: 16
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

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

        let container = InstrumentedLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir, maxConcurrentForks: 2)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let admissionGate = profile.standard.forkAdmissionGate
        let root = profile.standard.makeSession()

        // Two forks fit the admission ceiling and are admitted immediately.
        var forkA: RoutedSession? = try await root.fork(workingDirectory: nil)
        let forkB: RoutedSession? = try await root.fork(workingDirectory: nil)
        #expect(admissionGate.availablePermits == 0)
        _ = forkA
        _ = forkB

        // A third fork must await a free admission slot.
        let thirdTask = Task { try await root.fork(workingDirectory: nil) }
        await Self.spin(until: { admissionGate.waiterCount == 1 })

        // Releasing one fork frees its slot; the waiter is admitted. (The ceiling
        // was never exceeded while all three were requested: the parked-state
        // assertions above — two admitted, the third blocked on the gate — are the
        // robust bound evidence for the ceiling itself.)
        forkA = nil
        let third = try await thirdTask.value

        _ = forkB
        _ = third
        _ = root
    }
}
