import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the persistent-``LanguageModelSessionBackend``-per-session seam
/// (see ``RoutedSessionActor``) purely against stubs: the same backend
/// instance must serve every turn on a session (not a fresh one rebuilt per
/// call), ``RoutedSession/fork(workingDirectory:)`` must seed the child's
/// backend from a *copy* of the parent's accumulated call history via
/// ``LanguageModelSessionBackend/makeFork()``, and that `makeFork()` call must
/// happen strictly after any in-flight generation on the parent has released
/// the model's serial gate — never concurrently with it.
///
/// The companion gated integration suite
/// (`Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`)
/// proves the same properties against a real `LanguageModelSession`, plus the
/// harder KV-cache-reuse claim (`cachedTokenCount > 0` on a second turn) that
/// only a real model can demonstrate. This suite needs no network and no GPU.
@Suite("Multi-turn session state: same backend across turns, fork seeding, no fork/generate race")
struct MultiTurnSessionTests {
    // MARK: - Fork-tracking stub backend

    /// Wraps a ``StubSessionBackend``, proxying every generation call to it
    /// unchanged and additionally recording the most recently produced fork
    /// into ``lastFork`` — mirroring the pattern
    /// `SessionChokepointTests.MaxTokensRecordingBackend` and
    /// `ForkConcurrencyTests.TrackingSessionBackend` already use to observe a
    /// stub's fork history, since the shared ``StubSessionBackend`` itself has
    /// no way for a test holding the parent to reach the child `makeFork()`
    /// produces (``RoutedSession`` never exposes its backend directly).
    ///
    /// `@unchecked Sendable` is safe for the same reason `StubSessionBackend`
    /// is: `RoutedSessionActor` drives every method call on one backend
    /// through the model's serial gate, so there is never concurrent access to
    /// guard against in practice.
    private final class TrackingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The real stub every call is forwarded to.
        let backend: StubSessionBackend

        /// The most recent fork this backend produced, if any.
        private(set) var lastFork: TrackingBackend?

        init(backend: StubSessionBackend = StubSessionBackend()) {
            self.backend = backend
        }

        /// Proxies ``StubSessionBackend/callCount``.
        var callCount: Int { backend.callCount }

        /// Proxies ``StubSessionBackend/receivedPrompts``.
        var receivedPrompts: [String] { backend.receivedPrompts }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            try await backend.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            backend.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await backend.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        /// Proxies ``StubSessionBackend/transcriptEntries()``.
        func transcriptEntries() -> [Transcript.Entry] {
            backend.transcriptEntries()
        }

        /// Forks the wrapped stub and wraps the result the same way, recording
        /// it into ``lastFork`` so a test holding this (parent) instance can
        /// reach the child.
        func makeFork() -> any LanguageModelSessionBackend {
            guard let forkedStub = backend.makeFork() as? StubSessionBackend else {
                preconditionFailure("StubSessionBackend.makeFork() must return a StubSessionBackend")
            }
            let fork = TrackingBackend(backend: forkedStub)
            lastFork = fork
            return fork
        }
    }

    /// A ``LoadedLLMContainer`` that vends ``TrackingBackend``s and tracks the
    /// most recently manufactured one, so a test can reach it via
    /// ``lastBackend``.
    ///
    /// `@unchecked Sendable` is safe here because ``lastBackend`` is written
    /// exactly once per session, synchronously inside `makeSession(instructions:)`
    /// — itself only ever called from `RoutedModel.makeSession`, on the single
    /// `@MainActor` test task each test in this suite runs on — and every read
    /// happens afterward from that same task, so there is no concurrent access
    /// across isolation domains in practice.
    private final class TrackingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private(set) var lastBackend: TrackingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = TrackingBackend()
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let stub = StubSessionBackend(entries: Array(transcript))
            let backend = TrackingBackend(backend: stub)
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Parkable stub backend (serial-gate race proof)

    /// A synchronized event log a test polls without sleeping, recording the
    /// order generation and fork work actually ran in.
    ///
    /// A plain lock-guarded class rather than an actor: ``ParkableSessionBackend/makeFork()``
    /// is a synchronous, non-async protocol requirement, so it must record
    /// synchronously — an actor would force it onto a detached `Task`, losing
    /// the exact ordering this suite needs to observe.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ event: String) {
            lock.withLock { storage.append(event) }
        }

        var events: [String] {
            lock.withLock { storage }
        }
    }

    /// A ``LanguageModelSessionBackend`` whose `respond` parks on a
    /// test-controlled ``AsyncSemaphore`` after entering, so a test can hold a
    /// generation call open for as long as it needs to observe what a
    /// concurrent ``RoutedSession/fork(workingDirectory:)`` does while it is
    /// in flight. Every entry/exit and ``makeFork()`` call is timestamped into
    /// a shared ``EventLog``, in call order.
    ///
    /// `@unchecked Sendable` is safe because both stored properties are
    /// immutable references to independently `Sendable` types (``EventLog``
    /// is lock-guarded; `AsyncSemaphore` is itself `Sendable`), and
    /// `RoutedSessionActor` drives every method call on one backend through
    /// the model's serial gate — the very property this test suite proves —
    /// so there is no concurrent access to guard against in practice.
    private final class ParkableSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let log: EventLog
        private let releaseGate: AsyncSemaphore

        init(log: EventLog, releaseGate: AsyncSemaphore) {
            self.log = log
            self.releaseGate = releaseGate
        }

        /// Records entry, parks on ``releaseGate`` until the test signals it,
        /// then records exit — giving the test a window in which this
        /// backend's owning session is provably mid-generation.
        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            log.record("respond-enter")
            await releaseGate.wait()
            log.record("respond-exit")
            return "ok"
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            return "guided-ok"
        }

        /// No synthetic transcript is tracked here — nothing in this suite
        /// exercises this backend's transcript, only its parking/ordering
        /// behavior via ``log``.
        func transcriptEntries() -> [Transcript.Entry] {
            []
        }

        /// Records that a fork was produced, so a test can assert this never
        /// happens while a `respond-enter` has not yet been followed by a
        /// matching `respond-exit`.
        func makeFork() -> any LanguageModelSessionBackend {
            log.record("makeFork")
            return ParkableSessionBackend(log: log, releaseGate: releaseGate)
        }
    }

    /// A ``LoadedLLMContainer`` vending ``ParkableSessionBackend``s wired to a
    /// shared log and release gate.
    ///
    /// `@unchecked Sendable` is safe because both stored properties are `let`
    /// references to independently `Sendable`/lock-guarded types, set once at
    /// initialization and never mutated afterward.
    private final class ParkableLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private let log: EventLog
        private let releaseGate: AsyncSemaphore

        init(log: EventLog, releaseGate: AsyncSemaphore) {
            self.log = log
            self.releaseGate = releaseGate
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            ParkableSessionBackend(log: log, releaseGate: releaseGate)
        }
    }

    // MARK: - Stubs shared by every test in this suite

    /// A stub embedder container — never exercised here, present only so the
    /// profile resolves. No MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns a single, test-supplied
    /// ``LoadedLLMContainer`` for every generation slot and a stub embedder.
    /// No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let container: any LoadedLLMContainer
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
            .appendingPathComponent("MultiTurnSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for
    /// every generation slot.
    private static func makeRouter(
        container: any LoadedLLMContainer,
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

    /// Spins cooperatively until `condition` holds or a bounded number of
    /// yields elapse, so a scheduler-ordered state change is observed without
    /// a fixed sleep.
    private static func spin(until condition: @Sendable () async -> Bool) async {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Same backend serves every turn

    @Test("the same backend instance serves two respond() calls on one session")
    @MainActor
    func sameBackendServesTwoRespondCalls() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = TrackingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        _ = try await session.respond(to: "first turn")
        _ = try await session.respond(to: "second turn")

        // A fresh backend per call would show callCount == 1 on two distinct
        // instances (or two containers manufactured); a persistent backend
        // shows one instance whose callCount reaches 2, having seen both
        // prompts in order.
        let stubBackend = try #require(container.lastBackend)
        #expect(stubBackend.callCount == 2)
        #expect(stubBackend.receivedPrompts == ["first turn", "second turn"])
    }

    // MARK: - Fork seeds the child from a copy of the parent's history

    @Test("fork() gives the child a backend whose receivedPrompts starts as a copy of the parent's call history")
    @MainActor
    func forkChildBackendStartsWithCopyOfParentHistory() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = TrackingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let parent = profile.standard.makeSession()
        _ = try await parent.respond(to: "one")
        _ = try await parent.respond(to: "two")

        let parentBackend = try #require(container.lastBackend)
        #expect(parentBackend.receivedPrompts == ["one", "two"])

        let child = try await parent.fork(workingDirectory: nil)
        let childBackend = try #require(parentBackend.lastFork)

        // The child's backend begins holding exactly the parent's history as
        // of fork time, and has itself served no calls yet.
        #expect(childBackend.receivedPrompts == ["one", "two"])
        #expect(childBackend.callCount == 0)

        // It is a copy, not a live view: further parent turns do not
        // retroactively appear in the already-forked child's history, and the
        // child's own further turns do not appear in the parent's.
        _ = try await parent.respond(to: "three")
        _ = try await child.respond(to: "child turn")
        #expect(parentBackend.receivedPrompts == ["one", "two", "three"])
        #expect(childBackend.receivedPrompts == ["one", "two", "child turn"])
    }

    // MARK: - fork() holds the serial gate across makeFork()

    @Test("fork() holds the serial gate during makeFork(): an in-flight respond() and a concurrent fork() never race")
    @MainActor
    func forkHoldsSerialGateDuringMakeFork() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = EventLog()
        // Starts at 0: the in-flight respond() call parks on this until the
        // test explicitly signals it, holding the turn open indefinitely.
        let releaseGate = AsyncSemaphore(value: 0)
        let container = ParkableLLMContainer(log: log, releaseGate: releaseGate)
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        let serialGate = profile.standard.serialGate

        // Start a respond() call; it acquires the serial gate and parks inside
        // the backend body, holding the gate the whole time it is parked.
        let respondTask = Task { try await session.respond(to: "turn") }
        await Self.spin(until: { serialGate.availablePermits == 0 })
        await Self.spin(until: { log.events.contains("respond-enter") })

        // Concurrently start a fork. It must queue behind the serial gate
        // rather than reading (forking) the backend's state while the turn
        // above is still in flight — this is exactly the race
        // `RoutedSessionActor.fork()` closes by acquiring `serialGate` before
        // calling `backend.makeFork()`.
        let forkTask = Task { try await session.fork(workingDirectory: nil) }
        await Self.spin(until: { serialGate.waiterCount >= 1 })

        // The fork has not reached makeFork() yet: it is parked behind the
        // still-open respond() call.
        #expect(!log.events.contains("makeFork"))

        // Release the parked respond(); only once it completes and releases
        // the serial gate can the fork proceed to call makeFork().
        releaseGate.signal()
        _ = try await respondTask.value
        _ = try await forkTask.value

        #expect(log.events == ["respond-enter", "respond-exit", "makeFork"])
    }
}
