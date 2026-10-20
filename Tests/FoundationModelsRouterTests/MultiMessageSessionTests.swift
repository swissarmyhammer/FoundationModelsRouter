import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the persistent-``LanguageModelSessionBackend``-per-session seam
/// (see ``RoutedSessionActor``) purely against stubs: the same backend
/// instance must serve every answer on a session (not a fresh one rebuilt per
/// call), ``RoutedSession/fork(workingDirectory:)`` must seed the child's
/// backend from a *copy* of the parent's accumulated call history via
/// ``LanguageModelSessionBackend/makeFork()``, and a fork never waits for a
/// running submission on the parent: it seeds the child from the settled
/// transcript of the parent (task ^dpn2ytt).
///
/// The companion gated integration suite
/// (`Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`)
/// proves the same properties against a real `LanguageModelSession`, plus the
/// harder KV-cache-reuse claim (`cachedTokenCount > 0` on a second answer) that
/// only a real model can demonstrate. This suite needs no network and no GPU.
@Suite("Session state over many messages: same backend across answers, fork seeding, no fork/generate race")
struct MultiMessageSessionTests {
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
    /// through the owning session's pump, one at a time, so there is never concurrent access to
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

        /// Proxies ``StubSessionBackend/usageTokenCounts()``.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            backend.usageTokenCounts()
        }

        /// Proxies ``LanguageModelSessionBackend/cachedInputTokenCount()``.
        func cachedInputTokenCount() -> Int? {
            backend.cachedInputTokenCount()
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
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

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

    // MARK: - Suspendable stub backend (a fork during a submission)

    /// A synchronized event log that records the order generation and fork
    /// work actually ran in. Each record signals ``changes``, so a test waits
    /// for an entry with no clock.
    ///
    /// A plain lock-guarded class rather than an actor: ``SuspendableSessionBackend/makeFork()``
    /// is a synchronous, non-async protocol requirement, so it must record
    /// synchronously — an actor would force it onto a separate `Task`, losing
    /// the exact ordering this suite needs to observe.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        /// The signal that ``record(_:)`` sends after each entry. It is a
        /// constant of a `Sendable` type, so it adds nothing to the lock.
        let changes = ChangeSignal()

        /// Appends one entry, then signals ``changes`` after the lock.
        ///
        /// - Parameter event: The entry.
        func record(_ event: String) {
            lock.withLock { storage.append(event) }
            changes.signal()
        }

        /// Waits until the log holds `event`, or until `ended` holds the end
        /// of a test task (rule T1). The task records `event` before it can
        /// end, so in a test that passes the end never comes first.
        ///
        /// - Parameters:
        ///   - event: The entry to wait for.
        ///   - ended: The end of the task whose end also ends the wait. Its
        ///     signal must be ``changes``.
        ///   - sourceLocation: The place of the call, for the failure.
        /// - Throws: The error of `#require` when the task ended first, or
        ///   ``ConditionNeverHeld`` when the waiting task was cancelled first.
        func waitFor(
            _ event: String, endingOn ended: RecordedWaitResult,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            try await changes.wait(
                until: { self.events.contains(event) },
                endingOn: { ended.value != nil }, sourceLocation: sourceLocation)
        }

        var events: [String] {
            lock.withLock { storage }
        }
    }

    /// A ``LanguageModelSessionBackend`` whose `respond` suspends on a
    /// test-controlled ``AsyncSemaphore`` after entering, so a test can hold a
    /// generation call open for as long as it needs to observe what a
    /// concurrent ``RoutedSession/fork(workingDirectory:)`` does while it is
    /// in flight. Every entry/exit and ``makeFork()`` call is timestamped into
    /// a shared ``EventLog``, in call order.
    ///
    /// `@unchecked Sendable` is safe because both stored properties are
    /// immutable references to independently `Sendable` types (``EventLog``
    /// is lock-guarded; `AsyncSemaphore` is itself `Sendable`), and no method
    /// writes a stored property. A fork can call ``makeFork()`` while
    /// `respond` is suspended, and the two touch only the lock-guarded log.
    private final class SuspendableSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let log: EventLog
        private let releaseGate: AsyncSemaphore

        init(log: EventLog, releaseGate: AsyncSemaphore) {
            self.log = log
            self.releaseGate = releaseGate
        }

        /// Records entry, suspends on ``releaseGate`` until the test signals it,
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
        /// exercises this backend's transcript, only its suspension/ordering
        /// behavior via ``log``.
        func transcriptEntries() -> [Transcript.Entry] {
            []
        }

        /// No usage is tracked here — nothing in this suite exercises token
        /// metering, only suspension/ordering behavior via ``log``.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }

        /// Records that a fork was produced, so a test can assert where the
        /// fork falls between a `respond-enter` and its `respond-exit`.
        func makeFork() -> any LanguageModelSessionBackend {
            log.record("makeFork")
            return SuspendableSessionBackend(log: log, releaseGate: releaseGate)
        }
    }

    /// A ``LoadedLLMContainer`` vending ``SuspendableSessionBackend``s wired to a
    /// shared log and release gate.
    ///
    /// `@unchecked Sendable` is safe because both stored properties are `let`
    /// references to independently `Sendable`/lock-guarded types, set once at
    /// initialization and never mutated afterward.
    private final class SuspendableLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private let log: EventLog
        private let releaseGate: AsyncSemaphore

        init(log: EventLog, releaseGate: AsyncSemaphore) {
            self.log = log
            self.releaseGate = releaseGate
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSuspendableSessionBackend()
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeSuspendableSessionBackend()
        }

        private func makeSuspendableSessionBackend() -> any LanguageModelSessionBackend {
            SuspendableSessionBackend(log: log, releaseGate: releaseGate)
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
            .appendingPathComponent("MultiMessageSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for
    /// every generation slot.
    private static func makeRouter(
        container: any LoadedLLMContainer,
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

    // MARK: - Same backend serves every answer

    @Test("the same backend instance serves two respond() calls on one session")
    @MainActor
    func sameBackendServesTwoRespondCalls() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = TrackingLLMContainer()
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        defer { await session.close() }
        _ = try await session.respond(to: "first message")
        _ = try await session.respond(to: "second message")

        // A fresh backend per call would show callCount == 1 on two distinct
        // instances (or two containers manufactured); a persistent backend
        // shows one instance whose callCount reaches 2, having seen both
        // prompts in order.
        let stubBackend = try #require(container.lastBackend)
        #expect(stubBackend.callCount == 2)
        #expect(stubBackend.receivedPrompts == ["first message", "second message"])
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
        defer { await parent.close() }
        _ = try await parent.respond(to: "one")
        _ = try await parent.respond(to: "two")

        let parentBackend = try #require(container.lastBackend)
        #expect(parentBackend.receivedPrompts == ["one", "two"])

        let child = try await parent.fork(workingDirectory: nil)
        defer { await child.close() }
        let childBackend = try #require(parentBackend.lastFork)

        // The child's backend begins holding exactly the parent's history as
        // of fork time, and has itself served no calls yet.
        #expect(childBackend.receivedPrompts == ["one", "two"])
        #expect(childBackend.callCount == 0)

        // It is a copy, not a live view: further parent answers do not
        // retroactively appear in the already-forked child's history, and the
        // child's own further answers do not appear in the parent's.
        _ = try await parent.respond(to: "three")
        _ = try await child.respond(to: "child message")
        #expect(parentBackend.receivedPrompts == ["one", "two", "three"])
        #expect(childBackend.receivedPrompts == ["one", "two", "child message"])
    }

    // MARK: - fork() does not wait for an in-flight respond()

    @Test("fork() does not wait for an in-flight respond(): the fork completes while the submission is still suspended")
    @MainActor
    func forkDoesNotWaitForARunningSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = EventLog()
        // Starts at 0: the in-flight respond() call suspends on this until the
        // test explicitly signals it, holding the submission open indefinitely.
        let releaseGate = AsyncSemaphore(value: 0)
        let container = SuspendableLLMContainer(log: log, releaseGate: releaseGate)
        let router = Self.makeRouter(container: container, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // The gate opens before the close, also when a wait below throws, so
        // the suspended respond() call ends and the close does not wait for
        // it (rule T1). In a test that passes, the body opened the gate
        // already. The second permit is then not used: the respond() call
        // takes one permit, and a signal with no waiter only adds a permit.
        defer { await SessionFixtureLifecycle.close([session], releasing: [releaseGate], permits: 1) }

        // Start a respond() call; it suspends inside the backend body. The
        // pump of the session reaches the backend on a task of its own, so the
        // test waits for the entry that the backend records.
        // The wait also ends when the respond() call ended before it reached
        // the backend (rule T1).
        let respondTask = Task { try await session.respond(to: "message") }
        let respondEnded = RecordedWaitResult.recordingEnd(of: respondTask, reportingTo: log.changes)
        defer { respondEnded.stopRecording() }
        try await log.waitFor("respond-enter", endingOn: respondEnded)

        // A fork reads the settled transcript of the session, so it does not
        // wait for the submission above (task ^dpn2ytt). It makes the child's
        // backend while that submission is still suspended. Only the test
        // opens the gate of the submission, and it does so after this wait.
        // Thus a fork that waited for the submission never records its entry,
        // and the test stops here: a stack of the test process shows it. The
        // wait also ends when the fork ended with no entry (rule T1).
        let forkTask = Task { try await session.fork(workingDirectory: nil) }
        let forkEnded = RecordedWaitResult.recordingEnd(of: forkTask, reportingTo: log.changes)
        defer { forkEnded.stopRecording() }
        // The child of the fork closes also when a wait below throws (rule
        // T1). The fork does not wait for the held submission, so this wait
        // for its child ends before the gate opens.
        defer {
            if let child = try? await forkTask.value {
                await child.close()
            }
        }
        try await log.waitFor("makeFork", endingOn: forkEnded)
        let eventsWhileTheSubmissionIsSuspended = log.events

        releaseGate.signal()
        _ = try await respondTask.value
        let child = try await forkTask.value

        #expect(eventsWhileTheSubmissionIsSuspended == ["respond-enter", "makeFork"])
        #expect(child.parentId == session.id)
        #expect(log.events == ["respond-enter", "makeFork", "respond-exit"])
    }
}
