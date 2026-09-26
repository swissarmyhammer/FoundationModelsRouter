import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises human waits (`generation-queue.md`, section 5.5, rule 6). The
/// item of the per-model ``GenerationQueue`` is one whole submission to
/// Foundation (task ^1psqdm9), and a tool body runs inside its submission. So
/// a human wait inside a tool holds the model for every other session on it:
/// their submissions wait behind the submission of the wait. The way to wait
/// for a person without holding the model is an elicitation from a
/// background run. The session has no wrapper for a human wait: a tool body
/// waits for the person directly. A session has no lock (task ^3qx0mpt): its
/// pump runs the answer for the full wait, and a message that arrives
/// meanwhile waits in the outbox for the next submission.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, and that closure is the tool body
/// that waits for a person. Determinism comes from the observability of the
/// pump (``RoutedSessionActor/isPumpRunning``) and of the outbox
/// (``SessionOutbox/waitingMessageCount``) rather than from sleeps.
///
/// The complementary claim — that the order of submissions does not change
/// when no tool waits for a person — is covered where it already was:
/// `ForkConcurrencyTests.generationQueueSerializesSubmissionsAndIsFIFO` (four
/// callers over one model never overlap and run FIFO) and
/// `MultiMessageSessionTests.forkDoesNotWaitForARunningSubmission` (a fork does
/// not wait for a running submission; it reads the settled transcript).
@Suite("A human wait in a tool holds the model, and the session keeps its answer running")
struct HumanWaitGateTests {
    // MARK: - Failures raised from inside a human wait

    private enum ProbeError: Error, Equatable {
        case boom
    }

    // MARK: - Answer observability

    /// Records the order in which answers entered and left the model, and the
    /// peak number running at once, so non-overlap can be asserted rather than
    /// inferred.
    private actor AnswerObserver {
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

    // MARK: - Stub container + backend

    /// A ``LanguageModelSessionBackend`` that runs ``AnswerHook/midAnswer`` in
    /// the middle of `respond` — after it appends the `.prompt` entry of the
    /// submission and before its `.response` entry — so a test can observe
    /// what the rest of the system may do while an answer is suspended inside
    /// the model call, and whether anything reads a torn, half-appended
    /// transcript.
    ///
    /// It declares the queue of its container, so the session submits each
    /// whole call of this backend to that queue, as over a live container.
    ///
    /// Properly `Sendable`, like ``StubSessionBackend``: each mutable field is
    /// behind a ``Mutex``. A test reads ``lastFork`` and ``entries`` from its
    /// own task while the session drives the calls of this backend.
    private final class HookedSessionBackend: LanguageModelSessionBackend {
        private let hook: AnswerHook
        private let observer: AnswerObserver

        /// The queue of the container, which the session submits each whole
        /// call of this backend to.
        let generationQueue: GenerationQueue?

        /// This backend's synthetic transcript: one `.prompt` per call, plus one
        /// `.response` per call that ran to completion.
        private let transcript: Mutex<[Transcript.Entry]>

        /// This backend's synthetic transcript, as of this read.
        var entries: [Transcript.Entry] { transcript.withLock { $0 } }

        /// The most recent fork this backend produced, or `nil` when
        /// ``makeFork(tools:)`` has never been called.
        private let newestFork = Mutex<HookedSessionBackend?>(nil)

        /// The most recent fork this backend produced, or `nil` if
        /// ``makeFork(tools:)`` has never been called — the observation point
        /// proving *when* a concurrent fork read this backend's transcript.
        var lastFork: HookedSessionBackend? { newestFork.withLock { $0 } }

        init(hook: AnswerHook, observer: AnswerObserver, generationQueue: GenerationQueue?, entries: [Transcript.Entry] = []) {
            self.hook = hook
            self.observer = observer
            self.generationQueue = generationQueue
            self.transcript = Mutex(entries)
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            await observer.enter(prompt)
            if let midAnswer = hook.midAnswer {
                do {
                    try await midAnswer(prompt)
                } catch {
                    await observer.exit(prompt)
                    throw error
                }
            }
            let responseText = "ok-\(prompt)"
            append(.response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: responseText))])))
            await observer.exit(prompt)
            return responseText
        }

        /// Appends one entry to this backend's synthetic transcript.
        ///
        /// - Parameter entry: The entry to append.
        private func append(_ entry: Transcript.Entry) {
            transcript.withLock { $0.append(entry) }
        }

        /// Not exercised by this suite — every test here drives whole-response
        /// answers, where the mid-answer hook has a well-defined place to run.
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
            newestFork.withLock { $0 = fork }
            return fork
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer, retaining every one it manufactured so a test
    /// can reach a specific session's backend by creation order. Like a live
    /// container, it owns one ``GenerationQueue`` that every backend declares.
    ///
    /// Properly `Sendable`: the list of vended backends is behind a
    /// ``Mutex``, so a test can read ``backends`` while a session vends one.
    private final class HookedLLMContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private let hook: AnswerHook
        private let observer: AnswerObserver

        /// Every backend this container vended, in creation order.
        private let vended = Mutex<[HookedSessionBackend]>([])

        /// Every backend this container vended, in creation order, as of
        /// this read.
        var backends: [HookedSessionBackend] { vended.withLock { $0 } }

        /// The queue every backend of this container declares.
        let generationQueue = GenerationQueue()

        init(hook: AnswerHook, observer: AnswerObserver) {
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
            vended.withLock { $0.append(backend) }
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

    /// The prompt of a follow-up answer — the one answer a test runs after the
    /// behaviour it is about, to prove the session and the model still accept work.
    private static let followUpPrompt = "after"

    /// The reply a person gives to a wait outside any submission, so the test
    /// can read the same value back from the task that waited.
    private static let personReply = 42

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

    /// Thrown by ``completedRun(awaiting:named:finishedWhen:)`` when the run it waited
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
    private static func finished(named label: String, when condition: @Sendable () async -> Bool) async -> Bool {
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
        awaiting task: Task<Value, Error>,
        named label: String,
        finishedWhen condition: @Sendable () async -> Bool
    ) async throws -> Value {
        guard await finished(named: label, when: condition) else {
            task.cancel()
            throw RunNeverFinished()
        }
        return try await task.value
    }

    /// ``completedRun(awaiting:named:finishedWhen:)`` for a run that cannot fail.
    ///
    /// Swift declares `Task.value` separately for `Failure == Never`, so the two
    /// spellings cannot be one generic function; everything but the `try` is
    /// shared through ``finished(named:when:)``.
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
        awaiting task: Task<Value, Never>,
        named label: String,
        finishedWhen condition: @Sendable () async -> Bool
    ) async throws -> Value {
        guard await finished(named: label, when: condition) else {
            task.cancel()
            throw RunNeverFinished()
        }
        return await task.value
    }

    /// The value `answerTask` produced, awaited only once `observer` shows that
    /// the answer left the model — ``completedRun(awaiting:named:finishedWhen:)`` with
    /// the observation every ordinary answer in this suite is bounded by.
    ///
    /// Leaving the model call is the right point to await from: after it, the
    /// pump only records the submission and gives the answer, and neither
    /// waits for anything outside the session.
    ///
    /// - Parameters:
    ///   - answerTask: The task that waits for the answer.
    ///   - prompt: The prompt of that answer, as `observer` records it.
    ///   - observer: The observer that the model call of the answer reports to.
    /// - Returns: Whatever the answer returned.
    /// - Throws: ``RunNeverFinished`` when the answer never left the model,
    ///   after recording an issue; otherwise whatever the answer itself threw.
    private static func completedAnswer<Value: Sendable>(
        awaiting answerTask: Task<Value, Error>,
        prompt: String,
        observer: AnswerObserver
    ) async throws -> Value {
        try await completedRun(awaiting: answerTask, named: "the answer \(prompt)") {
            await observer.exited.contains(prompt)
        }
    }

    /// Whether one further ordinary answer on `session` runs to completion,
    /// observed through `observer` under ``BoundedWait``'s bound rather than by
    /// awaiting the answer, recording an issue when that answer never reaches
    /// the model.
    ///
    /// The indirection is the point: a regression that strands the pump
    /// blocks every later message on that session forever, so awaiting such an
    /// answer directly would hang the whole suite instead of failing an
    /// assertion in the test that caught it.
    private static func followUpAnswerCompletes(
        on session: any RoutedSession,
        observer: AnswerObserver,
        prompt: String = followUpPrompt
    ) async -> Bool {
        let task = Task { try await session.respond(to: prompt) }
        let reachedTheModel = await BoundedWait.conditionReached("the follow-up answer \(prompt) leaving the model") {
            await observer.exited.contains(prompt)
        }
        guard reachedTheModel else {
            // Never admitted to the model at all — its message was stranded. The
            // suite must not await it.
            task.cancel()
            return false
        }
        // Past the model call now, so nothing left in this answer can strand it,
        // and awaiting it cannot hang.
        return (try? await task.value) != nil
    }

    /// Whether `entry` is a `.response` — how a test tells a whole recorded
    /// submission from one torn open at the prompt.
    private static func isResponse(entry: Transcript.Entry?) -> Bool {
        guard case .response = entry else { return false }
        return true
    }

    /// The one live model handle every session in a test is vended from, plus the
    /// container, observer, and hook wired behind it — the fixture every test in
    /// this suite starts from.
    private struct Fixture {
        let container: HookedLLMContainer
        let observer: AnswerObserver
        let hook: AnswerHook

        /// Retained for the fixture's whole lifetime: a ``RoutedLLM`` holds its
        /// owning profile weakly, so dropping this would make `makeSession` trap.
        let profile: LanguageModelProfile

        /// The one resident model every session in a test is vended from.
        var model: RoutedLLM { profile.standard }
    }

    /// Resolves a stub profile and returns its `standard` handle plus the shared
    /// hook/observer wired into every backend it will vend.
    private static func makeFixture(cacheDir: URL) async throws -> Fixture {
        let hook = AnswerHook()
        let observer = AnswerObserver()
        let container = HookedLLMContainer(hook: hook, observer: observer)
        let router = makeRouter(container: container, cacheDir: cacheDir)
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return Fixture(container: container, observer: observer, hook: hook, profile: profile)
    }

    // MARK: - A human wait in a tool holds the model

    @Test("an answer whose tool body waits for a person holds the model, so another session over the same model runs after the wait")
    @MainActor
    func humanWaitHoldsTheModelForAnotherSession() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let queue = fixture.container.generationQueue

        // Two root sessions over the SAME model.
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The tool body of A's submission waits on `humanGate`, as a tool that
        // waits for a person does. The body signals `waitStarted` from inside
        // the wait, so the test resumes at a point where A is provably in the
        // wait, rather than after a bounded number of scheduler hops.
        let humanGate = AsyncSemaphore(value: 0)
        let waitStarted = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "a-wait" else { return }
            waitStarted.signal()
            await humanGate.wait()
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

        // A then finishes its own answer, and only then does B run.
        humanGate.signal()
        #expect(try await Self.completedAnswer(awaiting: taskA, prompt: "a-wait", observer: fixture.observer) == "ok-a-wait")
        #expect(try await Self.completedAnswer(awaiting: taskB, prompt: "b", observer: fixture.observer) == "ok-b")
        #expect(await fixture.observer.exited == ["a-wait", "b"])
        #expect(await fixture.observer.maxActive == 1)
        #expect(await sessionA.becomesIdle())
        #expect(await queue.isRunning == false)
    }

    // MARK: - A message that arrives during a wait waits for the next submission

    @Test("a second respond on one session waits in the outbox, not in the running submission, while a tool body of that session waits for a person")
    @MainActor
    func secondRespondWaitsInTheOutboxDuringAHumanWait() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "first" else { return }
            await humanGate.wait()
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

        // Only once the human wait ends and the first answer completes does the
        // second one run — in submission order, never interleaved.
        humanGate.signal()
        #expect(try await Self.completedAnswer(awaiting: firstTask, prompt: "first", observer: fixture.observer) == "ok-first")
        #expect(try await Self.completedAnswer(awaiting: secondTask, prompt: "second", observer: fixture.observer) == "ok-second")
        #expect(await fixture.observer.entered == ["first", "second"])
        #expect(await fixture.observer.maxActive == 1)
    }

    @Test("a fork racing a submission whose tool body waits for a person returns at once, from the settled transcript, never a half-appended one")
    @MainActor
    func forkRacingAHumanWaitReadsTheSettledTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let backend = try #require(fixture.container.backends.first)

        let humanGate = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "answer" else { return }
            await humanGate.wait()
        }

        // The submission suspends mid-transcript: its `.prompt` entry is
        // appended, its `.response` entry is not. Anything that reads the live
        // transcript now reads a torn submission.
        let answerTask = Task { try await session.respond(to: "answer") }
        await BoundedWait.spin(until: { humanGate.waiterCount == 1 })
        #expect(Self.isResponse(entry: backend.transcriptEntries().last) == false)

        // The fork reads the settled transcript of the session, so it does not
        // wait for the submission (task ^dpn2ytt). It makes its child while the
        // human wait is still open.
        let forkTask = Task { try await session.fork(workingDirectory: nil) }
        let forkedDuringTheWait = await BoundedWait.conditionReached("the fork making its child") {
            backend.lastFork != nil
        }

        humanGate.signal()
        #expect(try await Self.completedAnswer(awaiting: answerTask, prompt: "answer", observer: fixture.observer) == "ok-answer")
        let child = try await forkTask.value

        #expect(forkedDuringTheWait)
        let childBackend = try #require(backend.lastFork)
        // No submission of the session had settled when the fork read it, so
        // the child holds nothing of the torn submission.
        #expect(childBackend.transcriptEntries().isEmpty)
        #expect(child.parentId == session.id)
    }

    // MARK: - The failure paths strand nothing

    @Test("a tool body that throws after its wait for a person fails the answer and leaves the session idle")
    @MainActor
    func throwingFromAHumanWaitPropagatesAndLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The person has already replied with a refusal, so the wait ends at
        // once, and the tool body then throws.
        let refusal = AsyncSemaphore(value: 1)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "throwing" else { return }
            await refusal.wait()
            throw ProbeError.boom
        }

        // The answer runs as its own task, and the test observes its unwind
        // before it awaits it: its tool waits on a person, so a regression on
        // the entry or exit route of that wait suspends the answer forever, and
        // a bare `await session.respond(to:)` here would hang the whole
        // `swift test` run instead of failing this test. The observer records
        // the exit from the model call on the throwing path as much as on the
        // returning one.
        let answerTask = Task { try await session.respond(to: "throwing") }
        guard await Self.finished(named: "the throwing answer", when: { await fixture.observer.exited.contains("throwing") })
        else { return }
        await #expect(throws: ProbeError.boom) {
            try await answerTask.value
        }

        // The session is idle again — the failure stranded nothing.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        // The proof that accounting really is balanced: the session still works.
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        #expect(await session.becomesIdle())
    }

    @Test("cancelling a task while its tool body waits for a person leaves the session idle")
    @MainActor
    func cancellingInsideAHumanWaitLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // `insideWait` is signalled from inside the wait, so the test cancels at
        // a point where the answer is provably suspended on a person rather than
        // racing to get there; `suspended` is what the wait actually suspends on,
        // released by the cancellation handler — the shape a real elicitation
        // awaiting a reply has, rather than a poll of `Task.isCancelled`.
        let insideWait = AsyncSemaphore(value: 0)
        let suspended = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "cancelled" else { return }
            await withTaskCancellationHandler {
                insideWait.signal()
                await suspended.wait()
            } onCancel: {
                suspended.signal()
            }
            try Task.checkCancellation()
        }

        let answerTask = Task { try await session.respond(to: "cancelled") }
        try await BoundedWait.awaitSignal(insideWait, named: "the answer suspending inside its human wait")
        #expect(await session.isPumpRunning)

        answerTask.cancel()
        // The answer unwinds only once the cancellation reaches its suspended
        // body, so the test observes the unwind before it awaits it: a
        // cancellation that never arrives fails this test with a readable
        // message rather than hanging.
        guard await Self.finished(named: "the cancelled answer", when: { await fixture.observer.exited.contains("cancelled") })
        else { return }
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }

        // The cancelled answer ends, and nothing of it waits.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    // MARK: - Consecutive waits, and waits outside any submission

    @Test("two waits for a person one after the other in one tool body both run while the answer keeps running, and the session is idle after")
    @MainActor
    func overlappingHumanWaitsKeepTheAnswerRunning() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Two waits in one submission — what a tool that asks a person two
        // questions, one after the other, looks like to the session.
        let firstEntered = AsyncSemaphore(value: 0)
        let releaseFirst = AsyncSemaphore(value: 0)
        let secondEntered = AsyncSemaphore(value: 0)
        let releaseSecond = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "nested" else { return }
            firstEntered.signal()
            await releaseFirst.wait()
            secondEntered.signal()
            await releaseSecond.wait()
        }

        let answerTask = Task { try await session.respond(to: "nested") }
        try await BoundedWait.awaitSignal(firstEntered, named: "the first human wait being entered")

        // The first wait is open, and the answer still runs: a wait releases
        // nothing, and no message waits.
        #expect(await session.isPumpRunning)
        #expect(await session.outbox.waitingMessageCount == 0)

        releaseFirst.signal()
        try await BoundedWait.awaitSignal(secondEntered, named: "the second human wait being entered")

        // The second wait is open, and the answer still runs.
        #expect(await session.isPumpRunning)
        #expect(await session.outbox.waitingMessageCount == 0)

        releaseSecond.signal()
        #expect(try await Self.completedAnswer(awaiting: answerTask, prompt: "nested", observer: fixture.observer) == "ok-nested")
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)
    }

    @Test(
        "a wait for a person outside any submission, open while an answer runs, leaves the session idle after the answer",
        .timeLimit(.minutes(1)))
    @MainActor
    func waitOverlappingAnotherAnswerLeavesTheSessionIdle() async throws {
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
        // This answer suspends in the backend, and the wait for a person below
        // is not part of it: it comes from a plain task outside any submission,
        // which is what an upstream coordinator that cannot see whether a
        // submission runs looks like. The order of the two is not promised; the
        // session must still become idle after them, because a stranded pump is
        // permanent.
        let inAnswer = AwaitedEvent()
        let releaseAnswer = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "answer" else { return }
            inAnswer.signal()
            await releaseAnswer.wait()
        }

        let answerFinished = AwaitedEvent()
        let answerTask = Task {
            defer { answerFinished.signal() }
            return try await session.respond(to: "answer")
        }
        try await inAnswer.wait()
        #expect(await session.isPumpRunning)

        // The wait outside the submission takes nothing and gives nothing back.
        // `waitFinished` is signalled after the wait ends, so the whole exit of
        // the wait is observable without awaiting the task that could be
        // suspended in it.
        let waitEntered = AwaitedEvent()
        let releaseWait = AsyncSemaphore(value: 0)
        let waitFinished = AwaitedEvent()
        let waitTask = Task {
            waitEntered.signal()
            await releaseWait.wait()
            waitFinished.signal()
        }
        try await waitEntered.wait()
        #expect(await session.isPumpRunning)

        // The end of the submission ends the answer.
        releaseAnswer.signal()
        try await answerFinished.wait()
        #expect(try await answerTask.value == "ok-answer")
        #expect(await session.becomesIdle())

        // The wait ending after the answer must not wake the pump again.
        releaseWait.signal()
        try await waitFinished.wait()
        await waitTask.value
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        // With no submission running, a further wait must still see an idle
        // session. It runs as its own task, so the test reads the state from
        // outside the wait rather than from the task that is inside it.
        let tailWaitFinished = AwaitedEvent()
        let tailWaitTask = Task {
            #expect(await session.becomesIdle())
            tailWaitFinished.signal()
        }
        try await tailWaitFinished.wait()
        await tailWaitTask.value

        // The proof that accounting really is balanced: one further ordinary
        // answer on this session still runs to completion.
        let followUpFinished = AwaitedEvent()
        let followUpTask = Task {
            defer { followUpFinished.signal() }
            return try await session.respond(to: Self.followUpPrompt)
        }
        try await followUpFinished.wait()
        #expect(try await followUpTask.value == "ok-\(Self.followUpPrompt)")
        #expect(await session.becomesIdle())
    }

    @Test("an answer that ends while a wait for a person outside any submission is open strands nothing: the model family keeps generating")
    @MainActor
    func answerEndingDuringAWaitOutsideASubmissionStrandsNothing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The mirror image of `waitOverlappingAnotherAnswerLeavesTheSessionIdle`:
        // there the wait ended after the answer, here the answer ends while the
        // wait is still open and another session waits for its own answer.
        // Before, the wait took a generation permit again on its way out, and an
        // answer that ended in that window could strand the permit. Now a wait
        // holds nothing and takes nothing back, so no order of these events can
        // strand work.
        let inAnswerA = AsyncSemaphore(value: 0)
        let releaseAnswerA = AsyncSemaphore(value: 0)
        let inAnswerB = AsyncSemaphore(value: 0)
        let releaseAnswerB = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            switch prompt {
            case "answer-a":
                inAnswerA.signal()
                await releaseAnswerA.wait()
            case "answer-b":
                inAnswerB.signal()
                await releaseAnswerB.wait()
            default:
                break
            }
        }

        // A's pump runs its answer, which suspends without any wait of its own.
        let answerA = Task { try await sessionA.respond(to: "answer-a") }
        try await BoundedWait.awaitSignal(inAnswerA, named: "sessionA's answer reaching the model")
        #expect(await sessionA.isPumpRunning)

        // A wait outside any submission opens. `waitFinished` is signalled
        // after the wait ends, so the end of the wait is observable without
        // awaiting a task that could be suspended in it.
        let waitEntered = AsyncSemaphore(value: 0)
        let releaseWait = AsyncSemaphore(value: 0)
        let waitFinished = AsyncSemaphore(value: 0)
        let waitTask = Task {
            waitEntered.signal()
            await releaseWait.wait()
            waitFinished.signal()
        }
        try await BoundedWait.awaitSignal(waitEntered, named: "the human wait outside any submission being entered")
        #expect(await sessionA.isPumpRunning)

        // B starts its own answer on the same model. Its submission waits behind
        // A's, which holds the model.
        let answerB = Task { try await sessionB.respond(to: "answer-b") }
        #expect(
            await BoundedWait.conditionReached("sessionB's submission waiting behind sessionA's") {
                await fixture.container.generationQueue.waitingCount == 1
            })
        #expect(await sessionB.isPumpRunning)

        // A's answer ends *while* the wait is still open, and B's submission
        // then reaches the model.
        releaseAnswerA.signal()
        #expect(try await Self.completedAnswer(awaiting: answerA, prompt: "answer-a", observer: fixture.observer) == "ok-answer-a")
        #expect(await sessionA.becomesIdle())
        try await BoundedWait.awaitSignal(inAnswerB, named: "sessionB's answer reaching the model")

        // The wait ends next. It takes nothing back, so it does not suspend.
        releaseWait.signal()
        try await Self.completedRun(awaiting: waitTask, named: "the human wait outside any submission") {
            waitFinished.availablePermits > 0
        }
        #expect(await sessionA.becomesIdle())

        releaseAnswerB.signal()
        #expect(try await Self.completedAnswer(awaiting: answerB, prompt: "answer-b", observer: fixture.observer) == "ok-answer-b")
        #expect(await sessionB.becomesIdle())

        // The behavioral consequence: both sessions over this model still accept
        // a further answer.
        #expect(await Self.followUpAnswerCompletes(on: sessionA, observer: fixture.observer, prompt: "after-a"))
        #expect(await Self.followUpAnswerCompletes(on: sessionB, observer: fixture.observer, prompt: "after-b"))
    }

    @Test("a wait for a person outside any submission runs, starts no pump, and leaves the session idle")
    @MainActor
    func waitOutsideASubmissionStartsNoPump() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The wait runs as its own task and bounded rather than awaited
        // outright: a regression on the entry or exit route of the wait
        // suspends it forever, and this target sets no `.timeLimit` trait, so a
        // bare await would hang the whole `swift test` run instead of failing
        // this test.
        #expect(await session.becomesIdle())
        let reply = AsyncSemaphore(value: 0)
        let waitEntered = AsyncSemaphore(value: 0)
        let answered = AsyncSemaphore(value: 0)
        let waitTask = Task { () -> Int in
            waitEntered.signal()
            await reply.wait()
            answered.signal()
            return Self.personReply
        }
        try await BoundedWait.awaitSignal(waitEntered, named: "the human wait outside any submission being entered")

        // The wait is open, and no pump runs: a wait outside a submission
        // starts no work of the session.
        #expect(await session.isPumpRunning == false)

        reply.signal()
        let answer = try await Self.completedRun(awaiting: waitTask, named: "the human wait outside any submission") {
            answered.availablePermits > 0
        }
        #expect(answer == Self.personReply)

        // Still idle: the wait takes nothing and gives nothing back.
        #expect(await session.becomesIdle())
        #expect(await session.outbox.waitingMessageCount == 0)

        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        #expect(await session.becomesIdle())
    }
}
