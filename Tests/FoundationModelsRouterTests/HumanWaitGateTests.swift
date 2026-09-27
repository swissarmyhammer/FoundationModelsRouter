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
/// that waits for a person.
///
/// Every moment a test here waits for is a signal that the run which reaches
/// the moment sends (task ^1qpmghh): an ``AwaitedEvent`` from the tool body or
/// from the end of a task, ``SessionEvent/submissionQueued(_:)`` for a
/// submission that waits behind another, and the end of the pump task of the
/// session for an idle session. One state has no signal — a message that waits
/// in the outbox — and the test reads it through ``AwaitedCondition``, which
/// has no deadline of its own. No wait here ends on a wall clock, so a loaded
/// machine makes these tests slower and never red. Before, each wait gave up
/// after the five seconds of ``BoundedWait``, and a full parallel `swift test`
/// that starved the main actor for longer failed a correct test. What ends a
/// test whose moment never comes is the `.timeLimit` of the suite: a ceiling
/// on a fault, and never a budget for the work.
///
/// The complementary claim — that the order of submissions does not change
/// when no tool waits for a person — is covered where it already was:
/// `ForkConcurrencyTests.generationQueueSerializesSubmissionsAndIsFIFO` (four
/// callers over one model never overlap and run FIFO) and
/// `MultiMessageSessionTests.forkDoesNotWaitForARunningSubmission` (a fork does
/// not wait for a running submission; it reads the settled transcript).
@Suite(
    "A human wait in a tool holds the model, and the session keeps its answer running",
    .timeLimit(.minutes(1)))
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

        /// Sent when this backend makes its first fork, so a test waits for
        /// the fork on the event rather than reading ``lastFork`` again and
        /// again.
        let forkMade = AwaitedEvent()

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
            let responseText = HumanWaitGateTests.reply(to: prompt)
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
            forkMade.signal()
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

    /// A task a test starts, with the event the task sends when it ends.
    ///
    /// A test reads the value only through ``value()``, never through a bare
    /// `await task.value`. A regression that strands a message suspends the
    /// run on an answer that never comes, and `Task.value` does not end on the
    /// cancellation that the `.timeLimit` of the suite sends, so a bare await
    /// would hang the whole `swift test` run instead of failing the test that
    /// caught the fault. The event is a wait that the cancellation ends. Past
    /// the event the task has ended, so the read of its value cannot suspend.
    private struct ObservedRun<Value: Sendable>: Sendable {
        /// The task that runs the body.
        private let task: Task<Value, Error>

        /// Sent when ``task`` ends, by a return or by a throw.
        private let ended: AwaitedEvent

        /// Starts `body` on a task of its own.
        ///
        /// - Parameter body: The work of the run.
        init(_ body: @escaping @Sendable () async throws -> Value) {
            let ended = AwaitedEvent()
            self.ended = ended
            task = Task {
                defer { ended.signal() }
                return try await body()
            }
        }

        /// What the run returned, read once the run has ended.
        ///
        /// - Returns: The value of the run.
        /// - Throws: ``EventNeverArrived`` when the `.timeLimit` of the suite
        ///   ended the wait before the run ended; otherwise what the run threw.
        func value() async throws -> Value {
            try await ended.wait()
            return try await task.value
        }

        /// Cancels the run, as a caller that stops its wait cancels its own
        /// task. Read the result with ``value()``.
        func cancel() {
            task.cancel()
        }
    }

    /// Thrown by the run of ``submissionQueued(on:)`` when the event stream of
    /// the session ended with no ``SessionEvent/submissionQueued(_:)``.
    private struct SubmissionNeverQueued: Error {}

    /// A run that ends when `session` reports that a submission of it waits
    /// behind another submission on its model.
    ///
    /// The report is ``SessionEvent/submissionQueued(_:)``. The queue of the
    /// model sends it when the submission joins the waiting list, so the end
    /// of this run is the signal of that moment. The subscription is open when
    /// this function returns, so start the answer after the call.
    ///
    /// - Parameter session: The session whose submission is to wait.
    /// - Returns: The run that ends on the report.
    private static func submissionQueued(on session: any RoutedSession) async -> ObservedRun<Void> {
        let events = await session.streamSessionEvents()
        return ObservedRun {
            for await event in events {
                if case .submissionQueued = event { return }
            }
            throw SubmissionNeverQueued()
        }
    }

    /// The reply of one further ordinary answer on `session`: the proof that
    /// the session and its model still accept work.
    ///
    /// - Parameters:
    ///   - session: The session to answer on.
    ///   - prompt: The prompt of the answer.
    /// - Returns: The reply of the answer.
    /// - Throws: What the answer throws, or ``EventNeverArrived`` when the
    ///   `.timeLimit` of the suite ended the wait.
    private static func followUpAnswer(
        on session: any RoutedSession,
        prompt: String = followUpPrompt
    ) async throws -> String {
        try await ObservedRun { try await session.respond(to: prompt) }.value()
    }

    /// The reply the stub backend gives to `prompt`.
    ///
    /// - Parameter prompt: The prompt of an answer.
    /// - Returns: The reply of that answer.
    private static func reply(to prompt: String) -> String {
        "ok-\(prompt)"
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
        // waits for a person does. The body sends `waitStarted` from inside
        // the wait, so the test resumes at a point where A is provably in the
        // wait.
        let humanGate = AsyncSemaphore(value: 0)
        let waitStarted = AwaitedEvent()
        fixture.hook.midAnswer = { prompt in
            guard prompt == "a-wait" else { return }
            waitStarted.signal()
            await humanGate.wait()
        }

        let answerA = ObservedRun { try await sessionA.respond(to: "a-wait") }
        try await waitStarted.wait()

        // A's pump keeps its answer running for the full wait.
        #expect(await sessionA.isPumpRunning)

        // B's submission waits behind A's: the wait is a step of A's submission,
        // so it holds the worker of the model.
        let queuedB = await Self.submissionQueued(on: sessionB)
        let answerB = ObservedRun { try await sessionB.respond(to: "b") }
        try await queuedB.value()
        #expect(await queue.waitingCount == 1)
        #expect(await fixture.observer.entered == ["a-wait"])

        // A then finishes its own answer, and only then does B run.
        humanGate.signal()
        #expect(try await answerA.value() == Self.reply(to: "a-wait"))
        #expect(try await answerB.value() == Self.reply(to: "b"))
        #expect(await fixture.observer.exited == ["a-wait", "b"])
        #expect(await fixture.observer.maxActive == 1)
        #expect(try await sessionA.isIdleOnceThePumpEnds())
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
        let waitStarted = AwaitedEvent()
        fixture.hook.midAnswer = { prompt in
            guard prompt == "first" else { return }
            waitStarted.signal()
            await humanGate.wait()
        }

        let first = ObservedRun { try await session.respond(to: "first") }
        try await waitStarted.wait()

        // The second respond is a message. It waits in the outbox, and never
        // goes into the running submission, which keeps the model for the
        // whole wait. The outbox sends no event when a message joins it, so
        // the test reads the count until it holds.
        let second = ObservedRun { try await session.respond(to: "second") }
        try await AwaitedCondition.wait(until: { session.outbox.messages.depth.waiting == 1 })

        #expect(await fixture.observer.entered == ["first"])
        #expect(await fixture.observer.maxActive == 1)

        // Only once the human wait ends and the first answer completes does the
        // second one run — in submission order, never interleaved.
        humanGate.signal()
        #expect(try await first.value() == Self.reply(to: "first"))
        #expect(try await second.value() == Self.reply(to: "second"))
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
        let waitStarted = AwaitedEvent()
        fixture.hook.midAnswer = { prompt in
            guard prompt == "answer" else { return }
            waitStarted.signal()
            await humanGate.wait()
        }

        // The submission suspends mid-transcript: its `.prompt` entry is
        // appended, its `.response` entry is not. Anything that reads the live
        // transcript now reads a torn submission.
        let answer = ObservedRun { try await session.respond(to: "answer") }
        try await waitStarted.wait()
        #expect(Self.isResponse(entry: backend.transcriptEntries().last) == false)

        // The fork reads the settled transcript of the session, so it does not
        // wait for the submission (task ^dpn2ytt). It makes its child while the
        // human wait is still open: the test waits for the child before it
        // ends the wait, so a fork that waited for the submission would never
        // make it, and the `.timeLimit` of the suite would end this test.
        let fork = ObservedRun { try await session.fork(workingDirectory: nil) }
        try await backend.forkMade.wait()

        humanGate.signal()
        #expect(try await answer.value() == Self.reply(to: "answer"))
        let child = try await fork.value()

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

        // The answer runs as its own task, and the test waits for the end of
        // that task on its event: its tool waits on a person, so a regression
        // on the entry or exit route of that wait suspends the answer forever,
        // and a bare `await session.respond(to:)` here would hang the whole
        // `swift test` run instead of failing this test.
        let answer = ObservedRun { try await session.respond(to: "throwing") }
        await #expect(throws: ProbeError.boom) {
            try await answer.value()
        }

        // The session is idle again — the failure stranded nothing.
        #expect(try await session.isIdleOnceThePumpEnds())

        // The proof that accounting really is balanced: the session still works.
        #expect(try await Self.followUpAnswer(on: session) == Self.reply(to: Self.followUpPrompt))
        #expect(try await session.isIdleOnceThePumpEnds())
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
        let insideWait = AwaitedEvent()
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

        let answer = ObservedRun { try await session.respond(to: "cancelled") }
        try await insideWait.wait()
        #expect(await session.isPumpRunning)

        answer.cancel()
        // The test waits for the end of the answer on its event: a
        // cancellation that never arrives leaves that event unsent, and the
        // `.timeLimit` of the suite then ends this test rather than hanging
        // the run.
        await #expect(throws: CancellationError.self) {
            try await answer.value()
        }

        // The cancelled answer ends, and nothing of it waits. The pump ends
        // only once the cancellation reached the suspended body and the
        // model call unwound.
        #expect(try await session.isIdleOnceThePumpEnds())

        #expect(try await Self.followUpAnswer(on: session) == Self.reply(to: Self.followUpPrompt))
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
        let firstEntered = AwaitedEvent()
        let releaseFirst = AsyncSemaphore(value: 0)
        let secondEntered = AwaitedEvent()
        let releaseSecond = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt == "nested" else { return }
            firstEntered.signal()
            await releaseFirst.wait()
            secondEntered.signal()
            await releaseSecond.wait()
        }

        let answer = ObservedRun { try await session.respond(to: "nested") }
        try await firstEntered.wait()

        // The first wait is open, and the answer still runs: a wait releases
        // nothing, and no message waits.
        #expect(await session.isPumpRunning)
        #expect(session.outbox.messages.depth.waiting == 0)

        releaseFirst.signal()
        try await secondEntered.wait()

        // The second wait is open, and the answer still runs.
        #expect(await session.isPumpRunning)
        #expect(session.outbox.messages.depth.waiting == 0)

        releaseSecond.signal()
        #expect(try await answer.value() == Self.reply(to: "nested"))
        #expect(try await session.isIdleOnceThePumpEnds())
    }

    @Test("a wait for a person outside any submission, open while an answer runs, leaves the session idle after the answer")
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
        // the `.timeLimit` of the suite, so no wait here has to give up early to
        // keep the suite from hanging. The semaphores that remain are the ones
        // this test *signals* rather than waits on — a release the test itself
        // makes always arrives, so nothing about it can be late.
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

        let answer = ObservedRun { try await session.respond(to: "answer") }
        try await inAnswer.wait()
        #expect(await session.isPumpRunning)

        // The wait outside the submission takes nothing and gives nothing back.
        // The run sends its end event after the wait ends, so the whole exit of
        // the wait is observable without a bare await of the task that could be
        // suspended in it.
        let waitEntered = AwaitedEvent()
        let releaseWait = AsyncSemaphore(value: 0)
        let wait = ObservedRun {
            waitEntered.signal()
            await releaseWait.wait()
        }
        try await waitEntered.wait()
        #expect(await session.isPumpRunning)

        // The end of the submission ends the answer.
        releaseAnswer.signal()
        #expect(try await answer.value() == Self.reply(to: "answer"))
        #expect(try await session.isIdleOnceThePumpEnds())

        // The wait ending after the answer must not wake the pump again.
        releaseWait.signal()
        try await wait.value()
        #expect(try await session.isIdleOnceThePumpEnds())

        // With no submission running, a further wait must still see an idle
        // session. It runs as its own task, so the test reads the state from
        // outside the wait rather than from the task that is inside it.
        let tailWait = ObservedRun { try await session.isIdleOnceThePumpEnds() }
        #expect(try await tailWait.value())

        // The proof that accounting really is balanced: one further ordinary
        // answer on this session still runs to completion.
        #expect(try await Self.followUpAnswer(on: session) == Self.reply(to: Self.followUpPrompt))
        #expect(try await session.isIdleOnceThePumpEnds())
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
        let inAnswerA = AwaitedEvent()
        let releaseAnswerA = AsyncSemaphore(value: 0)
        let inAnswerB = AwaitedEvent()
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
        let answerA = ObservedRun { try await sessionA.respond(to: "answer-a") }
        try await inAnswerA.wait()
        #expect(await sessionA.isPumpRunning)

        // A wait outside any submission opens. The run sends its end event
        // after the wait ends, so the end of the wait is observable without a
        // bare await of a task that could be suspended in it.
        let waitEntered = AwaitedEvent()
        let releaseWait = AsyncSemaphore(value: 0)
        let wait = ObservedRun {
            waitEntered.signal()
            await releaseWait.wait()
        }
        try await waitEntered.wait()
        #expect(await sessionA.isPumpRunning)

        // B starts its own answer on the same model. Its submission waits behind
        // A's, which holds the model.
        let queuedB = await Self.submissionQueued(on: sessionB)
        let answerB = ObservedRun { try await sessionB.respond(to: "answer-b") }
        try await queuedB.value()
        #expect(await fixture.container.generationQueue.waitingCount == 1)
        #expect(await sessionB.isPumpRunning)

        // A's answer ends *while* the wait is still open, and B's submission
        // then reaches the model.
        releaseAnswerA.signal()
        #expect(try await answerA.value() == Self.reply(to: "answer-a"))
        #expect(try await sessionA.isIdleOnceThePumpEnds())
        try await inAnswerB.wait()

        // The wait ends next. It takes nothing back, so it does not suspend.
        releaseWait.signal()
        try await wait.value()
        #expect(try await sessionA.isIdleOnceThePumpEnds())

        releaseAnswerB.signal()
        #expect(try await answerB.value() == Self.reply(to: "answer-b"))
        #expect(try await sessionB.isIdleOnceThePumpEnds())

        // The behavioral consequence: both sessions over this model still accept
        // a further answer.
        #expect(try await Self.followUpAnswer(on: sessionA, prompt: "after-a") == Self.reply(to: "after-a"))
        #expect(try await Self.followUpAnswer(on: sessionB, prompt: "after-b") == Self.reply(to: "after-b"))
    }

    @Test("a wait for a person outside any submission runs, starts no pump, and leaves the session idle")
    @MainActor
    func waitOutsideASubmissionStartsNoPump() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The wait runs as its own task, and the test waits for its end on the
        // event of the run rather than awaiting it outright: a regression on
        // the entry or exit route of the wait suspends it forever, and a bare
        // await would hang the whole `swift test` run instead of failing this
        // test.
        #expect(try await session.isIdleOnceThePumpEnds())
        let personAnswers = AsyncSemaphore(value: 0)
        let waitEntered = AwaitedEvent()
        let wait = ObservedRun { () -> Int in
            waitEntered.signal()
            await personAnswers.wait()
            return Self.personReply
        }
        try await waitEntered.wait()

        // The wait is open, and no pump runs: a wait outside a submission
        // starts no work of the session.
        #expect(await session.isPumpRunning == false)

        personAnswers.signal()
        #expect(try await wait.value() == Self.personReply)

        // Still idle: the wait takes nothing and gives nothing back.
        #expect(try await session.isIdleOnceThePumpEnds())

        #expect(try await Self.followUpAnswer(on: session) == Self.reply(to: Self.followUpPrompt))
        #expect(try await session.isIdleOnceThePumpEnds())
    }
}
