import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises human waits (`generation-queue.md`, section 5.5, rule 6). The
/// item of the per-model ``GenerationQueue`` is one whole submission to
/// Foundation (task ^1psqdm9), and a tool body runs inside its submission. So
/// a human wait inside a tool holds the model for every other session on it:
/// their submissions wait behind the submission of the wait. The way to wait
/// for a person without holding the model is an elicitation from a
/// background run. ``RoutedSession/awaitingUser(_:)`` holds nothing and
/// releases nothing. A session has no lock (task ^3qx0mpt): its pump runs the
/// answer for the full wait, and a message that arrives meanwhile waits in the
/// outbox for the next submission.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, and that closure is what calls
/// `awaitingUser`. Determinism comes from the observability of the pump
/// (``RoutedSessionActor/isPumpRunning``) and of the outbox
/// (``SessionOutbox/waitingMessageCount``) rather than from sleeps.
///
/// The complementary claim — that turn serialization and ordering are unchanged
/// when nobody calls `awaitingUser` — is covered where it already was:
/// `ForkConcurrencyTests.generationQueueSerializesSubmissionsAndIsFIFO` (four
/// callers over one model never overlap and run FIFO) and
/// `MultiTurnSessionTests.forkDoesNotWaitForAnInFlightTurn` (a fork does not
/// wait for an in-flight turn; it reads the settled transcript).
@Suite("A human wait in a tool holds the model, and the session keeps its answer running")
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
    /// one hook can serve several sessions, suspending only the turn a test means
    /// to suspend.
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
    /// It declares the queue of its container, so the session submits each
    /// whole call of this backend to that queue, as over a live container.
    ///
    /// `@unchecked Sendable` is safe for the same reason ``StubSessionBackend``'s
    /// is: ``RoutedSessionActor`` drives one backend's calls one at a time,
    /// because its one pump submits the next item only after the result of
    /// the last one.
    private final class HookedSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let hook: TurnHook
        private let observer: TurnObserver

        /// The queue of the container, which the session submits each whole
        /// call of this backend to.
        let generationQueue: GenerationQueue?

        /// This backend's synthetic transcript: one `.prompt` per call, plus one
        /// `.response` per call that ran to completion.
        private(set) var entries: [Transcript.Entry]

        /// The most recent fork this backend produced, or `nil` if
        /// ``makeFork(tools:)`` has never been called — the observation point
        /// proving *when* a concurrent fork read this backend's transcript.
        private(set) var lastFork: HookedSessionBackend?

        init(hook: TurnHook, observer: TurnObserver, generationQueue: GenerationQueue?, entries: [Transcript.Entry] = []) {
            self.hook = hook
            self.observer = observer
            self.generationQueue = generationQueue
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
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: responseText))]))
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

        /// Not exercised by this suite — guided decoding is orthogonal to human
        /// waits, and has its own suite.
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

        /// Snapshots ``entries`` as of this call into the child, through
        /// ``makeFork(tools:seededFrom:)``.
        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            makeFork(tools: tools, seededFrom: Transcript(entries: entries))
        }

        /// Seeds the child from `transcript` and records the child into
        /// ``lastFork``, so a test can assert both *that* a fork was made and
        /// *what* it was seeded with. The session passes its settled
        /// transcript here, not the live ``entries``.
        func makeFork(tools: [any Tool], seededFrom transcript: Transcript) -> any LanguageModelSessionBackend {
            let fork = HookedSessionBackend(
                hook: hook, observer: observer, generationQueue: generationQueue, entries: Array(transcript))
            lastFork = fork
            return fork
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer, retaining every one it manufactured so a test
    /// can reach a specific session's backend by creation order. Like a live
    /// container, it owns one ``GenerationQueue`` that every backend declares.
    ///
    /// `@unchecked Sendable` is safe because ``backends`` is only appended to
    /// inside `makeSession`, itself only reached from `RoutedModel.makeSession`
    /// on the single `@MainActor` test task, and read from that same task.
    private final class HookedLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private let hook: TurnHook
        private let observer: TurnObserver
        private(set) var backends: [HookedSessionBackend] = []

        /// The queue every backend of this container declares.
        let generationQueue = GenerationQueue()

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
            let backend = HookedSessionBackend(
                hook: hook, observer: observer, generationQueue: generationQueue, entries: entries)
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
    /// every generation slot — so every session in a test shares one model.
    /// No download, no GPU.
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

    /// The prompt a follow-up turn sends — the one turn a test runs after the
    /// behaviour it is about, to prove the session and the model still accept work.
    private static let followUpPrompt = "after"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanWaitGateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stub loader, vending `container` for every
    /// generation slot.
    private static func makeRouter(
        container: HookedLLMContainer, cacheDir: URL, pool: ModelPool = ModelPool()
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

    /// Thrown by ``completedRun(_:named:finishedWhen:)`` when the run it waited
    /// on never finished, so the test that caught the fault stops there instead
    /// of awaiting a task that never resumes.
    private struct RunNeverFinished: Error {}

    /// Whether the run named `label` reached the point `condition` observes,
    /// inside ``BoundedWait``'s bound, recording an issue when it never did.
    ///
    /// - Parameters:
    ///   - label: What the run is, named in the recorded issue.
    ///   - condition: The observable effect that says the run got there.
    /// - Returns: Whether the run got there inside the bound.
    private static func finished(_ label: String, when condition: @Sendable () async -> Bool) async -> Bool {
        await BoundedWait.conditionReached("the end of \(label)", when: condition)
    }

    /// The value `task` produced, awaited only once `condition` shows the run
    /// reached the end of everything that can suspend it.
    ///
    /// Deliberately not a bare `await task.value`: a regression that strands a
    /// message suspends the run on an answer that never comes, so awaiting such
    /// a run directly hangs the whole `swift test` run — this target sets no
    /// `.timeLimit` trait — instead of failing the test that caught the fault.
    /// Past the observed point nothing left in the run can strand it, so
    /// awaiting from there cannot hang.
    ///
    /// - Parameters:
    ///   - task: The run to read a value from.
    ///   - label: What the run is, named in the recorded issue.
    ///   - condition: The observable effect that says the run got past every wait.
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
    ///   - condition: The observable effect that says the run got past every wait.
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
    /// Leaving the model call is the right point to await from: after it, the
    /// pump only records the submission and gives the answer, and neither
    /// waits for anything outside the session.
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
    /// observed through `observer` under ``BoundedWait``'s bound rather than by
    /// awaiting the turn, recording an issue when that turn never reaches the
    /// model.
    ///
    /// The indirection is the point: a regression that strands the pump
    /// blocks every later message on that session forever, so awaiting such a
    /// turn directly would hang the whole suite instead of failing an assertion
    /// in the test that caught it.
    private static func followUpTurnCompletes(
        on session: any RoutedSession,
        observer: TurnObserver,
        prompt: String = followUpPrompt
    ) async -> Bool {
        let task = Task { try await session.respond(to: prompt) }
        let reachedTheModel = await BoundedWait.conditionReached("the follow-up turn \(prompt) leaving the model") {
            await observer.exited.contains(prompt)
        }
        guard reachedTheModel else {
            // Never admitted to the model at all — its message was stranded. The
            // suite must not await it.
            task.cancel()
            return false
        }
        // Past the model call now, so nothing left in this turn can strand it,
        // and awaiting it cannot hang.
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

        /// The one resident model every session in a test is vended from.
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

    // MARK: - A human wait in a tool holds the model

    @Test("a turn suspended in awaitingUser holds the model, so another session over the same model runs after the wait")
    @MainActor
    func humanWaitHoldsTheModelForAnotherSession() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let queue = fixture.container.generationQueue

        // Two root sessions over the SAME model.
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // A's turn suspends on `humanGate` from inside `awaitingUser`, standing in
        // for a tool waiting on a person. `waitStarted` is signalled from inside
        // the wait body, so awaiting it resumes the test at a point where A is
        // provably in the wait, rather than after a bounded number of scheduler hops.
        let humanGate = AsyncSemaphore(value: 0)
        let waitStarted = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "a-wait" else { return }
            await sessionA.awaitingUser {
                waitStarted.signal()
                await humanGate.wait()
            }
        }

        let taskA = Task { try await sessionA.respond(to: "a-wait") }
        try await BoundedWait.awaitSignal(waitStarted, named: "the start of sessionA's human wait")

        // A's pump keeps its answer running for the full wait.
        #expect(await sessionA.isPumpRunning)

        // B's submission waits behind A's: the wait is a step of A's submission,
        // so it holds the worker of the model.
        let taskB = Task { try await sessionB.respond(to: "b") }
        #expect(
            await BoundedWait.conditionReached("sessionB's submission waiting behind the human wait") {
                await queue.waitingCount == 1
            })
        #expect(await fixture.observer.entered == ["a-wait"])

        // A then finishes its own turn, and only then does B run.
        humanGate.signal()
        #expect(try await Self.completedTurn(taskA, prompt: "a-wait", observer: fixture.observer) == "ok-a-wait")
        #expect(try await Self.completedTurn(taskB, prompt: "b", observer: fixture.observer) == "ok-b")
        #expect(await fixture.observer.exited == ["a-wait", "b"])
        #expect(await fixture.observer.maxActive == 1)
        #expect(await sessionA.becomesIdle())
        #expect(await queue.isRunning == false)
    }

    // MARK: - A message that arrives during a wait waits for the next submission

    @Test("a second respond on one session waits in the outbox, not in the running submission, while that session is inside awaitingUser")
    @MainActor
    func secondRespondWaitsInTheOutboxDuringAHumanWait() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "first" else { return }
            await session.awaitingUser { await humanGate.wait() }
        }

        let firstTask = Task { try await session.respond(to: "first") }
        await BoundedWait.spin(until: { humanGate.waiterCount == 1 })

        // The second respond is a message. It waits in the outbox, and never
        // goes into the running submission, which keeps the model for the
        // whole wait.
        let secondTask = Task { try await session.respond(to: "second") }
        #expect(
            await BoundedWait.conditionReached("the second message waiting in the outbox") {
                await session.outbox.waitingMessageCount == 1
            })

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

    @Test("a fork racing a turn suspended in awaitingUser returns at once, from the settled transcript, never a half-appended one")
    @MainActor
    func forkRacingAHumanWaitReadsTheSettledTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let backend = try #require(fixture.container.backends.first)

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "turn" else { return }
            await session.awaitingUser { await humanGate.wait() }
        }

        // The turn suspends mid-transcript: its `.prompt` entry is appended, its
        // `.response` entry is not. Anything reading the live transcript now
        // would read a torn turn.
        let turnTask = Task { try await session.respond(to: "turn") }
        await BoundedWait.spin(until: { humanGate.waiterCount == 1 })
        #expect(Self.isResponse(backend.transcriptEntries().last) == false)

        // The fork reads the settled transcript of the session, so it does not
        // wait for the turn (task ^dpn2ytt). It makes its child while the human
        // wait is still open.
        let forkTask = Task { try await session.fork(workingDirectory: nil) }
        let forkedDuringTheWait = await BoundedWait.conditionReached("the fork making its child") {
            backend.lastFork != nil
        }

        humanGate.signal()
        #expect(try await Self.completedTurn(turnTask, prompt: "turn", observer: fixture.observer) == "ok-turn")
        let child = try await forkTask.value

        #expect(forkedDuringTheWait)
        let childBackend = try #require(backend.lastFork)
        // No turn of the session had settled when the fork read it, so the
        // child holds nothing of the torn turn.
        #expect(childBackend.transcriptEntries().isEmpty)
        #expect(child.parentId == session.id)
    }

    // MARK: - The failure paths strand nothing

    @Test("throwing from inside awaitingUser propagates the error and leaves the session idle")
    @MainActor
    func throwingFromAHumanWaitPropagatesAndLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        fixture.hook.midTurn = { prompt in
            guard prompt == "throwing" else { return }
            try await session.awaitingUser { throw ProbeError.boom }
        }

        // The turn is run as its own task and its unwind observed before it is
        // awaited: its tool waits on a person, so a regression on that wait's
        // entry or exit route suspends the turn forever, and a bare
        // `await session.respond(to:)` here would hang the whole `swift test` run
        // instead of failing this test. The observer records leaving the model
        // call on the throwing path as much as the returning one.
        let turnTask = Task { try await session.respond(to: "throwing") }
        guard await Self.finished("the throwing turn", when: { await fixture.observer.exited.contains("throwing") })
        else { return }
        await #expect(throws: ProbeError.boom) {
            try await turnTask.value
        }

        // The session is idle again — the failure stranded nothing.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        // The proof that accounting really is balanced: the session still works.
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(await session.becomesIdle())
    }

    @Test("cancelling a task inside awaitingUser leaves the session idle")
    @MainActor
    func cancellingInsideAHumanWaitLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // `insideWait` is signalled from inside the wait, so the test cancels at
        // a point where the turn is provably suspended on a person rather than
        // racing to get there; `suspended` is what the wait actually suspends on,
        // released by the cancellation handler — the shape a real elicitation
        // awaiting a reply has, rather than a poll of `Task.isCancelled`.
        let insideWait = AsyncSemaphore(value: 0)
        let suspended = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "cancelled" else { return }
            try await session.awaitingUser {
                await withTaskCancellationHandler {
                    insideWait.signal()
                    await suspended.wait()
                } onCancel: {
                    suspended.signal()
                }
                try Task.checkCancellation()
            }
        }

        let turnTask = Task { try await session.respond(to: "cancelled") }
        try await BoundedWait.awaitSignal(insideWait, named: "the turn suspending inside its human wait")
        #expect(await session.isPumpRunning)

        turnTask.cancel()
        // The turn unwinds only once the cancellation reaches its suspended body, so
        // the unwind is observed before it is awaited: a cancellation that never
        // arrives fails this test with a readable message rather than hanging.
        guard await Self.finished("the cancelled turn", when: { await fixture.observer.exited.contains("cancelled") })
        else { return }
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }

        // The cancelled answer ends, and nothing of it waits.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
    }

    // MARK: - Overlapping and out-of-turn waits

    @Test("overlapping human waits in one turn both run while the answer keeps running, and the session is idle after")
    @MainActor
    func overlappingHumanWaitsKeepTheAnswerRunning() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Two waits outstanding at once — what two tools of one turn, each
        // awaiting a person, look like to the session.
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

        // Both waits are open, and the answer still runs: a wait releases
        // nothing, and no message waits.
        #expect(await session.isPumpRunning)
        #expect(await session.outbox.waitingMessageCount == 0)

        release.signal()
        #expect(try await Self.completedTurn(turnTask, prompt: "nested", observer: fixture.observer) == "ok-nested")
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)
    }

    @Test(
        "a human wait overlapping a turn it is not part of leaves the session idle after the turn",
        .timeLimit(.minutes(1)))
    @MainActor
    func waitOverlappingAnotherTurnLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Every moment this test waits for is an ``AwaitedEvent``, resumed by the
        // run that reaches it, rather than a reading polled until ``BoundedWait``'s
        // wall clock runs out (task ^q8cnmb2): a loaded machine makes this test
        // slower and never red. What ends a run that never reaches its moment is
        // the `.timeLimit` above, so no wait here has to give up early to keep the
        // suite from hanging. The semaphores that remain are the ones this test
        // *signals* rather than waits on — a release the test itself makes always
        // arrives, so nothing about it can be late.
        //
        // This turn suspends in the backend *without* calling `awaitingUser` — the
        // wait below comes from somewhere else entirely, which is what an
        // upstream coordinator that cannot see whether a turn is in flight looks
        // like. Outside `awaitingUser`'s documented precondition, so
        // serialization is not promised here; the session must still become
        // idle after it, because a stranded pump is permanent.
        let inTurn = AwaitedEvent()
        let releaseTurn = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "turn" else { return }
            inTurn.signal()
            await releaseTurn.wait()
        }

        let turnFinished = AwaitedEvent()
        let turnTask = Task {
            defer { turnFinished.signal() }
            return try await session.respond(to: "turn")
        }
        try await inTurn.wait()
        #expect(await session.isPumpRunning)

        // The out-of-turn wait takes nothing and gives nothing back.
        // `waitFinished` is signalled after `awaitingUser` returns, so the wait's
        // whole exit is observable without awaiting the task that could be
        // suspended in it.
        let waitEntered = AwaitedEvent()
        let releaseWait = AsyncSemaphore(value: 0)
        let waitFinished = AwaitedEvent()
        let waitTask = Task {
            await session.awaitingUser {
                waitEntered.signal()
                await releaseWait.wait()
            }
            waitFinished.signal()
        }
        try await waitEntered.wait()
        #expect(await session.isPumpRunning)

        // The turn ending ends the answer.
        releaseTurn.signal()
        try await turnFinished.wait()
        #expect(try await turnTask.value == "ok-turn")
        #expect(await session.becomesIdle())

        // The wait ending after the turn must not wake the pump again.
        releaseWait.signal()
        try await waitFinished.wait()
        await waitTask.value
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        // With no turn in flight, a further wait must still see an idle
        // session. Run as its own task, so the state is read from outside the
        // wait rather than from the task that is inside it.
        let tailWaitFinished = AwaitedEvent()
        let tailWaitTask = Task {
            await session.awaitingUser {
                #expect(await session.becomesIdle())
            }
            tailWaitFinished.signal()
        }
        try await tailWaitFinished.wait()
        await tailWaitTask.value

        // The proof that accounting really is balanced: one further ordinary turn
        // on this session still runs to completion.
        let followUpFinished = AwaitedEvent()
        let followUpTask = Task {
            defer { followUpFinished.signal() }
            return try await session.respond(to: Self.followUpPrompt)
        }
        try await followUpFinished.wait()
        #expect(try await followUpTask.value == "ok-\(Self.followUpPrompt)")
        #expect(await session.becomesIdle())
    }

    @Test("a turn ending while an out-of-turn human wait is open strands nothing: the model family keeps generating")
    @MainActor
    func turnEndingDuringAnOutOfTurnWaitStrandsNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The mirror image of `waitOverlappingAnotherTurnLeavesTheSessionIdle`:
        // there the wait ended after the turn, here the turn ends while the wait
        // is still open and another session waits for its own turn. Before, the
        // wait re-acquired a generation permit on its way out, and a turn that
        // ended in that window could strand the permit. Now a wait holds nothing
        // and takes nothing back, so no order of these events can strand work.
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

        // A's pump runs its answer, which suspends without any wait of its own.
        let turnA = Task { try await sessionA.respond(to: "turn-a") }
        try await BoundedWait.awaitSignal(inTurnA, named: "sessionA's turn reaching the model")
        #expect(await sessionA.isPumpRunning)

        // An out-of-turn wait opens on A. `waitFinished` is signalled after
        // `awaitingUser` returns, so the end of the wait is observable without
        // awaiting a task that could be suspended in it.
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
        #expect(await sessionA.isPumpRunning)

        // B starts its own turn on the same model. Its submission waits behind
        // A's, which holds the model.
        let turnB = Task { try await sessionB.respond(to: "turn-b") }
        #expect(
            await BoundedWait.conditionReached("sessionB's submission waiting behind sessionA's") {
                await fixture.container.generationQueue.waitingCount == 1
            })
        #expect(await sessionB.isPumpRunning)

        // A's turn ends *while* the out-of-turn wait is still open, and B's
        // submission then reaches the model.
        releaseTurnA.signal()
        #expect(try await Self.completedTurn(turnA, prompt: "turn-a", observer: fixture.observer) == "ok-turn-a")
        #expect(await sessionA.becomesIdle())
        try await BoundedWait.awaitSignal(inTurnB, named: "sessionB's turn reaching the model")

        // The wait ends next. It takes nothing back, so it does not suspend.
        releaseWait.signal()
        try await Self.completedRun(waitTask, named: "the out-of-turn human wait") {
            waitFinished.availablePermits > 0
        }
        #expect(await sessionA.becomesIdle())

        releaseTurnB.signal()
        #expect(try await Self.completedTurn(turnB, prompt: "turn-b", observer: fixture.observer) == "ok-turn-b")
        #expect(await sessionB.becomesIdle())

        // The behavioral consequence: both sessions over this model still accept
        // a further turn.
        #expect(await Self.followUpTurnCompletes(on: sessionA, observer: fixture.observer, prompt: "after-a"))
        #expect(await Self.followUpTurnCompletes(on: sessionB, observer: fixture.observer, prompt: "after-b"))
    }

    @Test("awaitingUser with no turn in flight runs the body, releases nothing, and starts no pump")
    @MainActor
    func awaitingUserWithNoTurnInFlightReleasesNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Run as its own task and bounded rather than awaited outright: a
        // regression on the wait's entry or exit route suspends it forever, and this
        // target sets no `.timeLimit` trait, so a bare await would hang the whole
        // `swift test` run instead of failing this test.
        #expect(await session.becomesIdle())
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

        // Still idle: the wait takes nothing and gives nothing back.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(await session.becomesIdle())
    }
}
