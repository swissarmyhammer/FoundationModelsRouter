import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the split gate (plan.md, "Human waits must not stall the model"):
/// one semaphore used to serialize both *a session's turns* and *a model's
/// generation*, so a tool call that awaited a person held the model hostage for
/// the whole wait. The two jobs are now separate — a per-session
/// ``RoutedSessionActor/turnLock`` for correctness and the per-model
/// ``RoutedModel/generationGate`` for throughput — and
/// ``RoutedSession/awaitingUser(_:)`` releases only the latter.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, and that closure is what calls
/// `awaitingUser`. Determinism comes from ``AsyncSemaphore``'s
/// `availablePermits`/`waiterCount` observability rather than from sleeps.
///
/// The complementary claim — that turn serialization and ordering are unchanged
/// when nobody calls `awaitingUser` — is covered where it already was:
/// `ForkConcurrencyTests.generationGateSerializesAndIsFIFO` (four callers over
/// one model never overlap and run FIFO) and
/// `MultiTurnSessionTests.forkHoldsTurnLockDuringMakeFork` (a fork queues behind
/// an in-flight turn).
@Suite("Human waits release the per-model generation gate, never the per-session turn lock")
struct HumanWaitGateTests {
    // MARK: - Failures raised from inside a human wait

    private enum ProbeError: Error, Equatable {
        case boom
    }

    // MARK: - Turn observability

    /// Records the order turns entered and left the model, and the peak number
    /// running at once, so non-overlap can be asserted rather than inferred.
    private actor TurnObserver {
        private(set) var entered: [String] = []
        private(set) var exited: [String] = []
        private(set) var active = 0
        private(set) var maxActive = 0

        func enter(_ prompt: String) {
            entered.append(prompt)
            active += 1
            maxActive = max(maxActive, active)
        }

        func exit(_ prompt: String) {
            exited.append(prompt)
            active -= 1
        }
    }

    /// The mid-generation closure a test installs, standing in for a tool the
    /// SDK invokes *inside* the model call. It is handed the turn's prompt so
    /// one hook can serve several sessions, parking only the turn a test means
    /// to park.
    ///
    /// A plain mutable class rather than an actor because
    /// ``HookedSessionBackend/respond(to:maxTokens:)`` reads it from whatever
    /// isolation the turn runs on: `@unchecked Sendable` is safe because
    /// ``midTurn`` is written exactly once, on the single `@MainActor` test task,
    /// before any turn is started, and only read afterwards.
    private final class TurnHook: @unchecked Sendable {
        var midTurn: (@Sendable (String) async throws -> Void)?
    }

    // MARK: - Stub container + backend

    /// A ``LanguageModelSessionBackend`` that runs ``TurnHook/midTurn`` in the
    /// middle of `respond` — after appending the turn's `.prompt` entry and
    /// before its `.response` entry — so a test can observe what the rest of the
    /// system may do while a turn is suspended inside the model call, and
    /// whether anything reads a torn, half-appended transcript.
    ///
    /// `@unchecked Sendable` is safe for the same reason ``StubSessionBackend``'s
    /// is: ``RoutedSessionActor`` drives one backend's calls one at a time, now
    /// under the session's own turn lock.
    private final class HookedSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let hook: TurnHook
        private let observer: TurnObserver

        /// This backend's synthetic transcript: one `.prompt` per call, plus one
        /// `.response` per call that ran to completion.
        private(set) var entries: [Transcript.Entry]

        /// The most recent fork this backend produced, or `nil` if
        /// ``makeFork(tools:)`` has never been called — the observation point
        /// proving *when* a concurrent fork read this backend's transcript.
        private(set) var lastFork: HookedSessionBackend?

        init(hook: TurnHook, observer: TurnObserver, entries: [Transcript.Entry] = []) {
            self.hook = hook
            self.observer = observer
            self.entries = entries
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            await observer.enter(prompt)
            if let midTurn = hook.midTurn {
                do {
                    try await midTurn(prompt)
                } catch {
                    await observer.exit(prompt)
                    throw error
                }
            }
            let responseText = "ok-\(prompt)"
            entries.append(
                .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))]))
            )
            await observer.exit(prompt)
            return responseText
        }

        /// Not exercised by this suite — every test here drives whole-response
        /// turns, where the mid-turn hook has a well-defined place to run.
        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }

        /// Not exercised by this suite — guided decoding is orthogonal to gate
        /// splitting, and has its own suite.
        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            return "guided-ok"
        }

        func transcriptEntries() -> [Transcript.Entry] {
            entries
        }

        /// No usage is tracked here — this suite exercises gating, not metering.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }

        func makeFork() -> any LanguageModelSessionBackend {
            makeFork(tools: [])
        }

        /// Snapshots ``entries`` as of this call into the child and records the
        /// child into ``lastFork``, so a test can assert both *that* a fork read
        /// this backend and *what* it saw.
        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            let fork = HookedSessionBackend(hook: hook, observer: observer, entries: entries)
            lastFork = fork
            return fork
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer, retaining every one it manufactured so a test
    /// can reach a specific session's backend by creation order.
    ///
    /// `@unchecked Sendable` is safe because ``backends`` is only appended to
    /// inside `makeSession`, itself only reached from `RoutedModel.makeSession`
    /// on the single `@MainActor` test task, and read from that same task.
    private final class HookedLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        private let hook: TurnHook
        private let observer: TurnObserver
        private(set) var backends: [HookedSessionBackend] = []

        init(hook: TurnHook, observer: TurnObserver) {
            self.hook = hook
            self.observer = observer
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: [])
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: Array(transcript))
        }

        private func makeHookedBackend(entries: [Transcript.Entry]) -> HookedSessionBackend {
            let backend = HookedSessionBackend(hook: hook, observer: observer, entries: entries)
            backends.append(backend)
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

    /// A ``ModelLoader`` returning the identical, test-supplied container for
    /// every generation slot — so every session in a test shares one model, and
    /// therefore one generation gate. No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let container: HookedLLMContainer
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
            .appendingPathComponent("HumanWaitGateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for every
    /// generation slot.
    private static func makeRouter(container: HookedLLMContainer, cacheDir: URL) -> Router {
        Router(
            maxConcurrentForks: 4,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    /// Thrown by ``completedRun(_:named:finishedWhen:)`` when the run it waited
    /// on never finished, so the test that caught the fault stops there instead
    /// of awaiting a task parked on a gate.
    private struct RunNeverFinished: Error {}

    /// Whether the run named `label` reached the point `condition` observes,
    /// inside ``BoundedWait``'s bound, recording an issue when it never did.
    ///
    /// - Parameters:
    ///   - label: What the run is, named in the recorded issue.
    ///   - condition: The observable effect that says the run got there.
    /// - Returns: Whether the run got there inside the bound.
    private static func finished(_ label: String, when condition: @Sendable () async -> Bool) async -> Bool {
        await BoundedWait.spin(until: condition)
        guard await condition() else {
            Issue.record("\(label) never finished: it is still parked, so something it waits on was never released")
            return false
        }
        return true
    }

    /// The value `task` produced, awaited only once `condition` shows the run
    /// reached the end of everything that can park it.
    ///
    /// Deliberately not a bare `await task.value`: a regression that strands a
    /// generation permit or a turn lock parks the run inside
    /// ``AsyncSemaphore/wait()``, which ignores cancellation by design, so
    /// awaiting such a run directly hangs the whole `swift test` run — this
    /// target sets no `.timeLimit` trait — instead of failing the test that
    /// caught the fault. Past the observed point nothing left in the run waits on
    /// a gate, so awaiting from there cannot hang.
    ///
    /// - Parameters:
    ///   - task: The run to read a value from.
    ///   - label: What the run is, named in the recorded issue.
    ///   - condition: The observable effect that says the run got past its gates.
    /// - Returns: Whatever the run returned.
    /// - Throws: ``RunNeverFinished`` when the run never got there, after
    ///   recording an issue; otherwise whatever the run itself threw.
    private static func completedRun<Value: Sendable>(
        _ task: Task<Value, Error>,
        named label: String,
        finishedWhen condition: @Sendable () async -> Bool
    ) async throws -> Value {
        guard await finished(label, when: condition) else {
            task.cancel()
            throw RunNeverFinished()
        }
        return try await task.value
    }

    /// ``completedRun(_:named:finishedWhen:)`` for a run that cannot fail.
    ///
    /// Swift declares `Task.value` separately for `Failure == Never`, so the two
    /// spellings cannot be one generic function; everything but the `try` is
    /// shared through ``finished(_:when:)``.
    ///
    /// - Parameters:
    ///   - task: The run to wait on.
    ///   - label: What the run is, named in the recorded issue.
    ///   - condition: The observable effect that says the run got past its gates.
    /// - Returns: Whatever the run returned.
    /// - Throws: ``RunNeverFinished`` when the run never got there, after
    ///   recording an issue.
    @discardableResult
    private static func completedRun<Value: Sendable>(
        _ task: Task<Value, Never>,
        named label: String,
        finishedWhen condition: @Sendable () async -> Bool
    ) async throws -> Value {
        guard await finished(label, when: condition) else {
            task.cancel()
            throw RunNeverFinished()
        }
        return await task.value
    }

    /// The value `turnTask` produced, awaited only once `observer` shows that
    /// turn left the model — ``completedRun(_:named:finishedWhen:)`` with the
    /// observation every ordinary turn in this suite is bounded by.
    ///
    /// Leaving the model call is the right point to await from: a turn's gates
    /// are taken before it and released by a `signal()` after it, and `signal()`
    /// cannot suspend.
    ///
    /// - Parameters:
    ///   - turnTask: The task running the turn.
    ///   - prompt: That turn's prompt, as `observer` records it.
    ///   - observer: The observer that turn's model call reports to.
    /// - Returns: Whatever the turn returned.
    /// - Throws: ``RunNeverFinished`` when the turn never reached the model,
    ///   after recording an issue; otherwise whatever the turn itself threw.
    private static func completedTurn<Value: Sendable>(
        _ turnTask: Task<Value, Error>,
        prompt: String,
        observer: TurnObserver
    ) async throws -> Value {
        try await completedRun(turnTask, named: "the turn \(prompt)") {
            await observer.exited.contains(prompt)
        }
    }

    /// Whether one further ordinary turn on `session` runs to completion,
    /// observed through `observer` under a bounded spin rather than by awaiting
    /// the turn.
    ///
    /// The indirection is the point: a regression that strands a generation permit
    /// parks every later turn over that model forever, so awaiting such a turn
    /// directly would hang the whole suite instead of failing an assertion in the
    /// test that caught it.
    private static func followUpTurnCompletes(
        on session: any RoutedSession,
        observer: TurnObserver,
        prompt: String = "after"
    ) async -> Bool {
        let task = Task { try await session.respond(to: prompt) }
        await BoundedWait.spin(until: { await observer.exited.contains(prompt) })
        guard await observer.exited.contains(prompt) else {
            // Never admitted to the model at all — parked on a gate. Cancelling
            // will not unpark it (``AsyncSemaphore/wait()`` ignores cancellation
            // by design), but the suite must not await it either.
            task.cancel()
            return false
        }
        // Past the model call now, so nothing left in this turn waits on a gate and
        // awaiting it cannot hang. Awaiting rather than returning here is what lets
        // a caller assert on permit counts afterwards without racing the turn's own
        // release.
        return (try? await task.value) != nil
    }

    /// Whether `entry` is a `.response` — how a test tells a whole recorded turn
    /// from one torn open at the prompt.
    private static func isResponse(_ entry: Transcript.Entry?) -> Bool {
        guard case .response = entry else { return false }
        return true
    }

    /// The one live model handle every session in a test is vended from, plus the
    /// container, observer, and hook wired behind it — the fixture every test in
    /// this suite starts from.
    private struct Fixture {
        let container: HookedLLMContainer
        let observer: TurnObserver
        let hook: TurnHook

        /// Retained for the fixture's whole lifetime: a ``RoutedLLM`` holds its
        /// owning profile weakly, so dropping this would make `makeSession` trap.
        let profile: LanguageModelProfile

        /// The one resident model every session in a test is vended from, and so
        /// the one generation gate they all share.
        var model: RoutedLLM { profile.standard }
    }

    /// Resolves a stub profile and returns its `standard` handle plus the shared
    /// hook/observer wired into every backend it will vend.
    private static func makeFixture(cacheDir: URL) async throws -> Fixture {
        let hook = TurnHook()
        let observer = TurnObserver()
        let container = HookedLLMContainer(hook: hook, observer: observer)
        let router = makeRouter(container: container, cacheDir: cacheDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return Fixture(container: container, observer: observer, hook: hook, profile: profile)
    }

    // MARK: - The regression: a human wait must not stall other sessions

    @Test("a turn parked in awaitingUser frees the per-model gate, so another session over the same model still generates")
    @MainActor
    func humanWaitLetsAnotherSessionOnTheSameModelGenerate() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate

        // Two root sessions over the SAME model, so they share one generation
        // gate — the arrangement that used to serialize a human wait against
        // every other session on the model.
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // A's turn parks on `humanGate` from inside `awaitingUser`, standing in
        // for a tool waiting on a person. `gateFreed` is signalled from inside
        // the wait body — ``RoutedSessionActor/awaitingUser(_:)`` releases the
        // generation permit before running its body — so awaiting it resumes the
        // test at a point where the gate release has provably happened, rather
        // than after a bounded number of scheduler hops.
        let humanGate = AsyncSemaphore(value: 0)
        let gateFreed = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "a-wait" else { return }
            await sessionA.awaitingUser {
                gateFreed.signal()
                await humanGate.wait()
            }
        }

        let taskA = Task { try await sessionA.respond(to: "a-wait") }
        try await BoundedWait.awaitSignal(gateFreed, named: "the gate release inside sessionA's human wait")

        // The gate is free while a person is being waited on — no model work is
        // in flight, so nothing is being protected by holding it.
        #expect(generationGate.availablePermits == 1)

        // …and that freedom is real: B runs a whole turn, start to finish, while
        // A is still parked, so `exited` is read after a finished turn instead
        // of racing the scheduler. B's finish is observed through the model call
        // it leaves before it is awaited, so a gate that was in fact still held
        // fails this test with a readable message instead of hanging the whole
        // run on an await that could never return.
        let taskB = Task { try await sessionB.respond(to: "b") }
        let responseB = try await Self.completedTurn(taskB, prompt: "b", observer: fixture.observer)
        #expect(await fixture.observer.exited == ["b"])

        // A then finishes its own turn normally, having re-acquired the gate.
        humanGate.signal()
        #expect(try await Self.completedTurn(taskA, prompt: "a-wait", observer: fixture.observer) == "ok-a-wait")
        #expect(responseB == "ok-b")
        #expect(await fixture.observer.exited == ["b", "a-wait"])
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)
    }

    // MARK: - The turn lock is never released early

    @Test("a second turn on one session still cannot start while that session is inside awaitingUser")
    @MainActor
    func secondTurnOnOneSessionStillBlocksDuringAHumanWait() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let turnLock = try #require(session as? RoutedSessionActor).turnLock

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "first" else { return }
            await session.awaitingUser { await humanGate.wait() }
        }

        let firstTask = Task { try await session.respond(to: "first") }
        await BoundedWait.spin(until: { humanGate.waiterCount == 1 })

        // The second turn is admitted into the actor (it is reentrant at the
        // parked await) but must park on the session's own turn lock, which the
        // first turn keeps for its whole duration.
        let secondTask = Task { try await session.respond(to: "second") }
        await BoundedWait.spin(until: { turnLock.waiterCount == 1 })

        #expect(await fixture.observer.entered == ["first"])
        #expect(await fixture.observer.maxActive == 1)

        // Only once the human wait ends and the first turn completes does the
        // second one run — in submission order, never interleaved.
        humanGate.signal()
        #expect(try await Self.completedTurn(firstTask, prompt: "first", observer: fixture.observer) == "ok-first")
        #expect(try await Self.completedTurn(secondTask, prompt: "second", observer: fixture.observer) == "ok-second")
        #expect(await fixture.observer.entered == ["first", "second"])
        #expect(await fixture.observer.maxActive == 1)
    }

    @Test("a fork racing a turn parked in awaitingUser still reads a whole turn, never a half-appended transcript")
    @MainActor
    func forkRacingAHumanWaitReadsAConsistentTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let turnLock = try #require(session as? RoutedSessionActor).turnLock
        let backend = try #require(fixture.container.backends.first)

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "turn" else { return }
            await session.awaitingUser { await humanGate.wait() }
        }

        // The turn parks mid-transcript: its `.prompt` entry is appended, its
        // `.response` entry is not. Anything reading the transcript now would
        // read a torn turn.
        let turnTask = Task { try await session.respond(to: "turn") }
        await BoundedWait.spin(until: { humanGate.waiterCount == 1 })
        #expect(Self.isResponse(backend.transcriptEntries().last) == false)

        let forkTask = Task { try await session.fork(workingDirectory: nil) }
        await BoundedWait.spin(until: { turnLock.waiterCount == 1 })

        // The fork is parked on the turn lock, so it has not read anything yet.
        #expect(backend.lastFork === nil)

        humanGate.signal()
        #expect(try await Self.completedTurn(turnTask, prompt: "turn", observer: fixture.observer) == "ok-turn")
        // The fork's own observation point is the transcript read it makes: it is
        // parked on the turn lock until the turn above hands that lock back, so a
        // lock that was never released fails here with a readable message rather
        // than hanging the run.
        let child = try await Self.completedRun(forkTask, named: "the fork racing the human wait") {
            backend.lastFork != nil
        }

        let childBackend = try #require(backend.lastFork)
        #expect(childBackend.transcriptEntries().count == backend.transcriptEntries().count)
        #expect(Self.isResponse(childBackend.transcriptEntries().last))
        #expect(child.parentId == session.id)
    }

    // MARK: - Permit accounting on the failure paths

    @Test("throwing from inside awaitingUser re-acquires the gate and propagates the error, leaking no permit")
    @MainActor
    func throwingFromAHumanWaitReAcquiresTheGateAndPropagates() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let session = fixture.model.makeSession()

        fixture.hook.midTurn = { prompt in
            guard prompt == "throwing" else { return }
            try await session.awaitingUser { throw ProbeError.boom }
        }

        // The turn is run as its own task and its unwind observed before it is
        // awaited: its tool waits on a person, so a regression on that wait's
        // entry or exit route parks the turn forever, and a bare
        // `await session.respond(to:)` here would hang the whole `swift test` run
        // instead of failing this test. The observer records leaving the model
        // call on the throwing path as much as the returning one.
        let turnTask = Task { try await session.respond(to: "throwing") }
        guard await Self.finished("the throwing turn", when: { await fixture.observer.exited.contains("throwing") })
        else { return }
        await #expect(throws: ProbeError.boom) {
            try await turnTask.value
        }

        // Exactly one permit is back — not two (a re-acquire skipped on the
        // throwing path) and not none (a permit stranded by the failure).
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)

        // The proof that accounting really is balanced: the session still works.
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(generationGate.availablePermits == 1)
    }

    @Test("cancelling a task inside awaitingUser leaves both gates balanced")
    @MainActor
    func cancellingInsideAHumanWaitLeavesGatesBalanced() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let session = fixture.model.makeSession()
        let turnLock = try #require(session as? RoutedSessionActor).turnLock

        // `insideWait` is signalled from inside the wait, so the test cancels at
        // a point where the turn is provably parked on a person rather than
        // racing to get there; `parked` is what the wait actually suspends on,
        // released by the cancellation handler — the shape a real elicitation
        // awaiting a reply has, rather than a poll of `Task.isCancelled`.
        let insideWait = AsyncSemaphore(value: 0)
        let parked = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "cancelled" else { return }
            try await session.awaitingUser {
                await withTaskCancellationHandler {
                    insideWait.signal()
                    await parked.wait()
                } onCancel: {
                    parked.signal()
                }
                try Task.checkCancellation()
            }
        }

        let turnTask = Task { try await session.respond(to: "cancelled") }
        try await BoundedWait.awaitSignal(insideWait, named: "the turn parking inside its human wait")
        #expect(generationGate.availablePermits == 1)

        turnTask.cancel()
        // The turn unwinds only once the cancellation reaches its parked body, so
        // the unwind is observed before it is awaited: a cancellation that never
        // arrives fails this test with a readable message rather than hanging.
        guard await Self.finished("the cancelled turn", when: { await fixture.observer.exited.contains("cancelled") })
        else { return }
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }

        // Acquisition completes even for a cancelled task (see
        // ``AsyncSemaphore``'s cancellation contract), so the cancelled wait
        // hands back exactly what it took.
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)
        #expect(turnLock.availablePermits == 1)
        #expect(turnLock.waiterCount == 0)

        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
    }

    // MARK: - Overlapping and out-of-turn waits

    @Test("overlapping human waits in one turn release the gate once and re-acquire it once")
    @MainActor
    func overlappingHumanWaitsReleaseExactlyOnce() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let session = fixture.model.makeSession()

        // Two waits outstanding at once — what two tools of one turn, each
        // awaiting a person, look like to the gate.
        let innerEntered = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "nested" else { return }
            await session.awaitingUser {
                await session.awaitingUser {
                    innerEntered.signal()
                    await release.wait()
                }
            }
        }

        let turnTask = Task { try await session.respond(to: "nested") }
        try await BoundedWait.awaitSignal(innerEntered, named: "the inner human wait being entered")

        // One permit back, not two: a second release would mint a permit the
        // session never held and let two real generations overlap.
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)

        release.signal()
        #expect(try await Self.completedTurn(turnTask, prompt: "nested", observer: fixture.observer) == "ok-nested")
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)
    }

    @Test("a human wait overlapping a turn it is not part of leaves the gate at exactly one permit")
    @MainActor
    func waitOverlappingAnotherTurnDoesNotInflateTheGate() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let session = fixture.model.makeSession()

        // This turn parks in the backend *without* calling `awaitingUser` — the
        // wait below comes from somewhere else entirely, which is what an
        // upstream coordinator that cannot see whether a turn is in flight looks
        // like. Outside `awaitingUser`'s documented precondition, so
        // serialization is not promised here; the gate's *count* must survive it
        // regardless, because a count that drifts is permanent.
        let inTurn = AsyncSemaphore(value: 0)
        let releaseTurn = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "turn" else { return }
            inTurn.signal()
            await releaseTurn.wait()
        }

        let turnTask = Task { try await session.respond(to: "turn") }
        try await BoundedWait.awaitSignal(inTurn, named: "the turn reaching the model")
        #expect(generationGate.availablePermits == 0)

        // The out-of-turn wait hands back the permit the turn is holding…
        // `waitFinished` is signalled after `awaitingUser` returns, so the wait's
        // whole exit — its re-acquire included — is observable without awaiting
        // the task that could be parked in it.
        let waitEntered = AsyncSemaphore(value: 0)
        let releaseWait = AsyncSemaphore(value: 0)
        let waitFinished = AsyncSemaphore(value: 0)
        let waitTask = Task {
            await session.awaitingUser {
                waitEntered.signal()
                await releaseWait.wait()
            }
            waitFinished.signal()
        }
        try await BoundedWait.awaitSignal(waitEntered, named: "the out-of-turn human wait being entered")
        #expect(generationGate.availablePermits == 1)

        // …so the turn ending must not signal a permit it no longer holds.
        releaseTurn.signal()
        #expect(try await Self.completedTurn(turnTask, prompt: "turn", observer: fixture.observer) == "ok-turn")
        #expect(generationGate.availablePermits == 1)

        // …and the wait must not re-acquire one on the way out, either: the turn
        // that lent it already gave it back.
        releaseWait.signal()
        try await Self.completedRun(waitTask, named: "the out-of-turn human wait") {
            waitFinished.availablePermits > 0
        }
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)

        // The bookkeeping behind the count is clean too, not just the count: with
        // no turn in flight there is nothing to hand back, so a further wait must
        // still see exactly one permit rather than mint a second. Run as its own
        // task and bounded for the same reason as the wait above: a human wait
        // that never returns must fail this test rather than hang the run.
        let tailWaitFinished = AsyncSemaphore(value: 0)
        let tailWaitTask = Task {
            await session.awaitingUser {
                #expect(generationGate.availablePermits == 1)
            }
            tailWaitFinished.signal()
        }
        try await Self.completedRun(tailWaitTask, named: "a further human wait with no turn in flight") {
            tailWaitFinished.availablePermits > 0
        }

        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(generationGate.availablePermits == 1)
    }

    @Test("a turn ending while a human wait's re-acquire is in flight strands no permit: the model family keeps generating")
    @MainActor
    func turnEndingDuringAReAcquireStrandsNoPermit() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The mirror image of `waitOverlappingAnotherTurnDoesNotInflateTheGate`:
        // there the turn outlived the wait, here the wait's *re-acquire* is still
        // suspended when its lending turn ends. The re-acquire is a real
        // suspension point, so the actor is reentrant across it and the turn's
        // `endTurn()` runs inside that window — which is why "was a permit held?"
        // has to be re-asked after the acquire, not only before it.
        let inTurnA = AsyncSemaphore(value: 0)
        let releaseTurnA = AsyncSemaphore(value: 0)
        let inTurnB = AsyncSemaphore(value: 0)
        let releaseTurnB = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            switch prompt {
            case "turn-a":
                inTurnA.signal()
                await releaseTurnA.wait()
            case "turn-b":
                inTurnB.signal()
                await releaseTurnB.wait()
            default:
                break
            }
        }

        // A's turn holds the permit and parks, without any wait of its own.
        let turnA = Task { try await sessionA.respond(to: "turn-a") }
        try await BoundedWait.awaitSignal(inTurnA, named: "sessionA's turn reaching the model")
        #expect(generationGate.availablePermits == 0)

        // An out-of-turn wait borrows A's permit. `waitFinished` is signalled
        // after `awaitingUser` returns, so the re-acquire this test is about is
        // observable without awaiting a task that could be parked in it.
        let waitEntered = AsyncSemaphore(value: 0)
        let releaseWait = AsyncSemaphore(value: 0)
        let waitFinished = AsyncSemaphore(value: 0)
        let waitTask = Task {
            await sessionA.awaitingUser {
                waitEntered.signal()
                await releaseWait.wait()
            }
            waitFinished.signal()
        }
        try await BoundedWait.awaitSignal(waitEntered, named: "the out-of-turn human wait being entered")
        #expect(generationGate.availablePermits == 1)

        // B takes the freed permit and parks too, so the re-acquire below cannot
        // complete promptly — it must genuinely suspend on the gate.
        let turnB = Task { try await sessionB.respond(to: "turn-b") }
        try await BoundedWait.awaitSignal(inTurnB, named: "sessionB's turn reaching the model")
        #expect(generationGate.availablePermits == 0)

        // The wait ends first, and its re-acquire is now provably in flight.
        releaseWait.signal()
        await BoundedWait.spin(until: { generationGate.waiterCount == 1 })
        #expect(generationGate.waiterCount == 1)

        // The lending turn ends *while* that re-acquire is suspended.
        releaseTurnA.signal()
        #expect(try await Self.completedTurn(turnA, prompt: "turn-a", observer: fixture.observer) == "ok-turn-a")

        // B hands its permit on to the suspended re-acquire, which must notice its
        // lender is gone and hand the permit straight back rather than sit on one
        // no turn will ever release.
        releaseTurnB.signal()
        #expect(try await Self.completedTurn(turnB, prompt: "turn-b", observer: fixture.observer) == "ok-turn-b")
        try await Self.completedRun(waitTask, named: "the out-of-turn human wait's re-acquire") {
            waitFinished.availablePermits > 0
        }
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)

        // The behavioral consequence, and the reason a stranded permit is worse
        // than a drifted count: it parks every later turn on every session and
        // fork over this model forever.
        #expect(await Self.followUpTurnCompletes(on: sessionB, observer: fixture.observer))
    }

    @Test("awaitingUser with no turn in flight runs the body and releases nothing")
    @MainActor
    func awaitingUserWithNoTurnInFlightReleasesNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let session = fixture.model.makeSession()

        // Run as its own task and bounded rather than awaited outright: a
        // regression on the wait's entry or exit route parks it forever, and this
        // target sets no `.timeLimit` trait, so a bare await would hang the whole
        // `swift test` run instead of failing this test.
        #expect(generationGate.availablePermits == 1)
        let answered = AsyncSemaphore(value: 0)
        let waitTask = Task { () -> Int in
            let value = await session.awaitingUser { 42 }
            answered.signal()
            return value
        }
        let answer = try await Self.completedRun(waitTask, named: "the human wait with no turn in flight") {
            answered.availablePermits > 0
        }
        #expect(answer == 42)

        // Still exactly one permit: with no turn in flight there was none held
        // to give back, and signalling anyway would have minted a second.
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)

        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(generationGate.availablePermits == 1)
    }
}
