import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 9: the ``RoutedSession/fork(workingDirectory:)`` primitive
/// over the persistent ``LanguageModelSessionBackend``, plus the per-model
/// ``GenerationQueue`` its submissions wait in.
///
/// Everything runs against stubs with no network and no GPU:
/// - a ``TrackingSessionBackend`` that records call count and prompt history
///   like the shared ``StubSessionBackend``, so a fork's ``makeFork()``-seeded
///   transcript inheritance and independent divergence are observed exactly;
/// - the same backend declares its container's queue, so the session submits
///   each whole call to it; when wired with a test-controlled
///   ``SerialObserver`` + release gate, the backend can suspend a call, so the
///   queue's non-overlap and FIFO order are made deterministic through the
///   ``SessionEvent/submissionQueued(_:)`` event of each waiting session
///   rather than sleeps.
///
/// Real prefix reuse (no recompute) is gated to the milestone 7 integration
/// suite; here the abstraction is asserted through the stub.
@Suite("Session fork + per-model generation queue")
struct ForkConcurrencyTests {
    // MARK: - Serial-queue observability

    /// Tracks the order `respond` bodies enter the model and the peak concurrency,
    /// so the generation queue's non-overlap and FIFO order can be asserted.
    private actor SerialObserver {
        private(set) var entryOrder: [Int] = []
        private(set) var active = 0
        private(set) var maxActive = 0

        /// The signal that ``enter(_:)`` sends after each entry, so a test
        /// waits for an entry with no clock.
        nonisolated let changes = ChangeSignal()

        func enter(_ id: Int) {
            entryOrder.append(id)
            active += 1
            maxActive = max(maxActive, active)
            changes.signal()
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
    /// additionally supports suspending a call on a test-controlled
    /// ``SerialObserver`` + release gate, and recording the grammar a guided
    /// call was constrained with into a ``GuidedProbe``, neither of which the
    /// other stub-container files in this target need. ``makeFork()``
    /// propagates the same wiring to the child, so a fork of an
    /// observer/gate-wired backend still suspends the same way and a fork of a
    /// guided-probe-wired backend still records into the same probe —
    /// mirroring how a fork shares its parent's underlying model.
    ///
    /// It declares the ``GenerationQueue`` its container owns
    /// (``LanguageModelSessionBackend/generationQueue``), so the session
    /// submits each whole call of this backend to that queue as one item
    /// (task ^1psqdm9).
    private final class TrackingSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var receivedPrompts: [String]
        private(set) var lastFork: TrackingSessionBackend?

        private let observer: SerialObserver?
        private let releaseGate: AsyncSemaphore?
        private let guidedProbe: GuidedProbe?

        /// The queue of the container, which the session submits each whole
        /// call of this backend to.
        let generationQueue: GenerationQueue?

        init(
            generationQueue: GenerationQueue?,
            observer: SerialObserver? = nil,
            releaseGate: AsyncSemaphore? = nil,
            guidedProbe: GuidedProbe? = nil,
            receivedPrompts: [String] = []
        ) {
            self.generationQueue = generationQueue
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
        /// call-count/prompt-history/generation-queue behavior, not
        /// transcript accumulation, so there is nothing meaningful to report.
        func transcriptEntries() -> [Transcript.Entry] {
            []
        }

        /// No usage is tracked here — this suite exercises call-count/prompt-
        /// history/generation-queue behavior, not token metering.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }

        /// Returns a new backend sharing this one's queue/observer/gate/probe
        /// wiring and pre-seeded with a copy of ``receivedPrompts`` as of this
        /// call, and records the child so a test holding this (parent) backend
        /// can reach it via ``lastFork``.
        func makeFork() -> any LanguageModelSessionBackend {
            let fork = TrackingSessionBackend(
                generationQueue: generationQueue,
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
    ///
    /// It owns one ``GenerationQueue``, and every backend it vends, and every
    /// fork of those, declares that one queue, so each of their calls is one
    /// submission to it.
    private final class InstrumentedLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The queue every backend of this container shares.
        let generationQueue = GenerationQueue()

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
            let backend = TrackingSessionBackend(
                generationQueue: generationQueue, observer: observer, releaseGate: releaseGate,
                guidedProbe: guidedProbe)
            lastBackend = backend
            return backend
        }

        /// Mirrors ``makeSession(instructions:)``'s queue/observer/gate/probe wiring
        /// and ``lastBackend`` tracking invariant instead of the shared plain
        /// default. `TrackingSessionBackend` never models a synthetic
        /// transcript (its ``TrackingSessionBackend/transcriptEntries()``
        /// always reports empty, by design — this suite exercises
        /// call-count/prompt-history/generation-queue behavior, not transcript
        /// accumulation), so `transcript`'s entries have nothing to seed; only
        /// the tracking invariant itself needs to be preserved here.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let backend = TrackingSessionBackend(
                generationQueue: generationQueue, observer: observer, releaseGate: releaseGate,
                guidedProbe: guidedProbe)
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
            "max_position_embeddings": 8192,
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
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
    }

    /// Gives `gate` one permit for each of `callers`, so each held call goes
    /// on.
    ///
    /// - Parameters:
    ///   - gate: The release gate of the held calls.
    ///   - callers: The sessions whose calls the gate holds.
    private static func release(_ gate: AsyncSemaphore, forEachOf callers: [any RoutedSession]) {
        for _ in callers {
            gate.signal()
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

        // An answer on the child does not retroactively appear in the parent's
        // history…
        let childText = try await child.respond(to: "child answer")
        #expect(childText == "ok")
        #expect(childBackend.receivedPrompts == ["child answer"])
        #expect(parentBackend.receivedPrompts.isEmpty)

        // …and a further parent answer is independent of the (now-diverged) child.
        let parentText = try await parent.respond(to: "parent answer")
        #expect(parentText == "ok")
        #expect(parentBackend.receivedPrompts == ["parent answer"])
        #expect(childBackend.receivedPrompts == ["child answer"])
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

    // MARK: - Per-model generation queue

    @Test("concurrent submissions on one model never overlap and run first in first out")
    @MainActor
    func generationQueueSerializesSubmissionsAndIsFIFO() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = SerialObserver()
        // Bodies suspend here; a permit per call is released once the test has
        // established the FIFO arrival order.
        let releaseGate = AsyncSemaphore(value: 0)
        let container = InstrumentedLLMContainer(observer: observer, releaseGate: releaseGate)
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Four callers over the SAME model: a root session and three forks. They
        // share the container's one generation queue, so their submissions
        // must serialize, each in the order it joined the queue.
        let root = profile.standard.makeSession()
        let fork1 = try await root.fork(workingDirectory: nil)
        let fork2 = try await root.fork(workingDirectory: nil)
        let fork3 = try await root.fork(workingDirectory: nil)
        let callers: [any RoutedSession] = [root, fork1, fork2, fork3]
        // The gate gives one permit for each call also when a wait below
        // throws, so no call stays held (rule T1). In a test that passes, the
        // body gave the permits already. These permits are then not used: each
        // call takes one permit, and a signal with no waiter only adds a
        // permit.
        defer { Self.release(releaseGate, forEachOf: callers) }

        let queue = container.generationQueue
        var feeds: [(log: SessionEventLog, drain: Task<Void, Never>)] = []
        for caller in callers.dropFirst() {
            feeds.append(await SessionEventLog.watch(caller))
        }
        defer { feeds.forEach { $0.drain.cancel() } }

        // Launch call 0; its submission runs on the worker and suspends.
        let task0 = Task { try await callers[0].respond(to: "0") }
        // The wait also ends when call 0 ends with no entry (rule T1). Call 0
        // cannot end before its entry, because the release gate holds it.
        let call0Ended = RecordedWaitResult.recordingEnd(of: task0, reportingTo: observer.changes)
        defer { call0Ended.stopRecording() }
        try await observer.changes.wait(
            until: { await observer.entryOrder == [0] }, endingOn: { call0Ended.value != nil })

        // Launch calls 1, 2, 3 one at a time, each only after the previous
        // submission has actually joined the queue — establishing a
        // deterministic FIFO arrival order without sleeping. The session
        // sends `submissionQueued` when its submission joins the queue. Each
        // wait also ends when the work of that session ends (rule T1). A call
        // cannot end before the release gate opens.
        let task1 = Task { try await callers[1].respond(to: "1") }
        try await feeds[0].log.waitForQueuedSubmissionsOrWorkEnd(1)
        let task2 = Task { try await callers[2].respond(to: "2") }
        try await feeds[1].log.waitForQueuedSubmissionsOrWorkEnd(1)
        let task3 = Task { try await callers[3].respond(to: "3") }
        try await feeds[2].log.waitForQueuedSubmissionsOrWorkEnd(1)
        #expect(await queue.waitingCount == callers.count - 1)

        // Only one pass has entered so far — the queue held the rest out.
        #expect(await observer.entryOrder == [0])
        #expect(await observer.maxActive == 1)

        // Release the chain; FIFO must admit them 1, 2, 3 in that order.
        Self.release(releaseGate, forEachOf: callers)

        _ = try await task0.value
        _ = try await task1.value
        _ = try await task2.value
        _ = try await task3.value

        #expect(await observer.entryOrder == [0, 1, 2, 3])
        #expect(await observer.maxActive == 1)
        #expect(await queue.isRunning == false)

        _ = callers
    }

    // MARK: - Forks are not counted

    /// How many forks ``forksOverOneModelAreNotCounted()`` makes over one
    /// model. The card names eight.
    private static let uncountedForkCount = 8

    @Test("eight forks over one model all exist at once; no fork waits for another to end")
    @MainActor
    func forksOverOneModelAreNotCounted() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = InstrumentedLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let root = profile.standard.makeSession()

        // Each fork is held in `forks` while the next one is made, so every
        // earlier fork is still alive when the last one returns. A gate that
        // counted forks would suspend one of these calls; none of them can.
        var forks: [any RoutedSession] = []
        for _ in 0..<Self.uncountedForkCount {
            forks.append(try await root.fork(workingDirectory: nil))
        }

        #expect(forks.count == Self.uncountedForkCount)
        #expect(Set(forks.map(\.id)).count == Self.uncountedForkCount)
        #expect(forks.allSatisfy { $0.parentId == root.id })
        withExtendedLifetime((root, forks)) {}
    }
}
