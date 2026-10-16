import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^x2aawec: ``RoutedSession/cancelAll()`` stops the running
/// answer and drops its later output, but the answer runs on until its work
/// ends. While it winds down, each live event of other work still reaches
/// ``RoutedSession/streamSessionEvents()``. Only the stopped work loses its
/// output.
///
/// Each test holds the answer at the gate of the backend. That gate does not
/// open at a cancel, so the stopped answer runs until the test closes the
/// session. Two fake background runs exist before the stop:
///
/// - The run of other work. An earlier answer started it, so its poster is
///   the mail of that answer. Its canceler waits at a gate, so the sweep of
///   the stop does not settle it.
/// - The run of the stopped answer. Its poster is the mail of the stopped
///   answer.
///
/// After the stop, each test posts one kind of event from each run. A post
/// to the outbox of the session ends after the session handled it, so the
/// test then closes the session and reads its feed to the end. The tests read
/// the order of the work, not a clock.
@Suite("Live events of other work reach the feed while the answer that cancelAll() stopped winds down")
struct StoppedAnswerOtherWorkEventTests {
    // MARK: - Constants

    /// The prefix of the directory of each session.
    private static let prefix = "StoppedAnswerOtherWorkEventTests"

    /// The prompt of the answer that the test stops.
    private static let heldPrompt = "answer that cancelAll() stops"

    /// The posts of one question: its `.elicitation` event.
    private static let questionPosts = 1

    // MARK: - Helpers

    /// One fake background run, the work that started it, and the gate that
    /// holds its body.
    private struct PostingRun {
        /// The completion token of the run.
        let token: String

        /// The origin of the work that started the run. Each post of the run
        /// has it, as each post of a real run has the origin of the task that
        /// started the run.
        let poster: Origin

        /// The gate that holds the body of the run.
        let gate: RunLatch

        /// The session of the run.
        let session: any RoutedSession

        /// A context of the run that posts to `sink`.
        ///
        /// - Parameter sink: Where the context posts.
        /// - Returns: The context.
        func context(postingTo sink: any OperationEventSink) -> ToolContext {
            PendingElicitationFixtures.makeContext(for: session, postingTo: sink, completionToken: token)
        }

        /// Runs `work` with ``poster`` as the origin of the task.
        ///
        /// - Parameter work: The posts of the run.
        /// - Throws: What `work` throws.
        func post(_ work: () async throws -> Void) async throws {
            try await OriginContext.$current.withValue(poster) {
                try await work()
            }
        }
    }

    /// One session whose held answer ``RoutedSession/cancelAll()`` stopped,
    /// with the run of other work and the run of the stopped answer.
    private struct StoppedAnswer {
        /// The fixture of the session.
        let fixture: BackgroundingSessionFixture

        /// The feed of the session, read up to the `signalDone` of the stop.
        var feed: AsyncStream<SessionOutput>.Iterator

        /// The run that an earlier answer started.
        let otherRun: PostingRun

        /// The run that the stopped answer started.
        let ownRun: PostingRun

        /// The gate that holds the stopped answer.
        let answerGate: RunLatch

        /// The hold of the canceler of ``otherRun``.
        let cancelerHold: CancelerHold

        /// Opens each gate, closes the session, and reads the feed to its end.
        ///
        /// - Returns: Each output of the feed after the `signalDone` of the
        ///   stop, in order.
        mutating func outputsToTheEnd() async -> [SessionOutput] {
            await fixture.end(opening: [cancelerHold.release, otherRun.gate, ownRun.gate, answerGate])
            return await SessionWorkEventTests.remainingOutputs(of: &feed)
        }
    }

    /// Starts a ``RunKind/process`` fake run with `poster` as the origin of
    /// the task that starts it. The body of the run ends only when the test
    /// opens its gate.
    ///
    /// - Parameters:
    ///   - fixture: The fixture of the session.
    ///   - poster: The origin of the work that starts the run.
    ///   - cancelerHold: The hold of the canceler of the run, or `nil`.
    /// - Returns: The run.
    /// - Throws: When the session is not a ``RoutedSessionActor``.
    private static func startRun(
        on fixture: BackgroundingSessionFixture, startedBy poster: Origin, holdingCancelerAt cancelerHold: CancelerHold? = nil
    ) async throws -> PostingRun {
        let gate = RunLatch()
        let runPlane = try fixture.sessionActor().runPlane
        let token = await OriginContext.$current.withValue(poster) {
            await trackFakeRun(on: runPlane, latch: gate, kind: .process, holdingCancelerAt: cancelerHold)
        }
        return PostingRun(token: token, poster: poster, gate: gate, session: fixture.session)
    }

    /// Makes the session, starts the held answer and the two runs, sends
    /// ``RoutedSession/cancelAll()``, and reads the feed up to its
    /// `signalDone`. Returns when the sweep of the stop runs the canceler of
    /// the run of other work, which waits at its hold.
    ///
    /// - Returns: The stopped answer and its session.
    /// - Throws: What the fixture throws, or ``ConditionNeverHeld``.
    private static func stopTheHeldAnswer() async throws -> StoppedAnswer {
        let answerGate = RunLatch()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: prefix, tools: [], container: BackgroundingLLMContainer(holdFirstAnswer: answerGate))
        try await fixture.sessionActor().attachOutboxJournalIfNeeded()
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let heldMail = try await MailQueueFixtures.startHeldAnswer(heldPrompt, on: fixture.session, backend: fixture.backend)
        let cancelerHold = CancelerHold()
        let otherRun = try await startRun(on: fixture, startedBy: .mail([MailID()]), holdingCancelerAt: cancelerHold)
        let ownRun = try await startRun(on: fixture, startedBy: .mail([heldMail]))

        let signal = fixture.session.cancelAll()
        _ = await SessionWorkEventTests.outputs(from: &feed, through: { $0 == .signalDone(signal) })
        await cancelerHold.entered.waitUntilOpen()
        return StoppedAnswer(
            fixture: fixture, feed: feed, otherRun: otherRun, ownRun: ownRun, answerGate: answerGate,
            cancelerHold: cancelerHold)
    }

    /// The completion token of the run of `event`, when `event` is a live
    /// event of a run or of a tool, or `nil`.
    ///
    /// - Parameter event: An event of a session.
    /// - Returns: The completion token.
    private static func runToken(of event: SessionEvent) -> String? {
        switch event {
        case .runProgress(let run), .runMessage(let run), .runSettled(let run), .elicitationRequested(let run):
            return run.correlationID
        case .toolInvocation(let record, _):
            return record.correlationID
        case .toolCallReport(let report):
            return report.correlationID
        case .toolDisplay(let display):
            return display.correlationID
        default:
            return nil
        }
    }

    /// Stops the held answer, runs `post` for the run of the stopped answer
    /// and then for the run of other work, and runs `wait`. Then checks the
    /// outputs of `kind`: the post of the run of other work comes one time,
    /// with the origin of its poster, and the post of the run of the stopped
    /// answer does not come.
    ///
    /// The stopped answer still runs when the posts end: the open answer is
    /// still the silenced answer.
    ///
    /// - Parameters:
    ///   - kind: The kind of the live event that the posts make.
    ///   - post: Makes the posts of one run.
    ///   - wait: Waits until the session handled the posts, when `post`
    ///     itself does not wait.
    /// - Throws: What the fixture, `post` or `wait` throws.
    private static func expectOnlyThePostOfOtherWork(
        of kind: SessionEventCase, posting post: (PostingRun) async throws -> Void,
        thenWaiting wait: (StoppedAnswer) async throws -> Void = { _ in }
    ) async throws {
        var stopped = try await stopTheHeldAnswer()
        try await post(stopped.ownRun)
        try await post(stopped.otherRun)
        try await wait(stopped)
        #expect(
            try stopped.fixture.sessionActor().openAnswerMail.isSilenced,
            "the stopped answer must still run when the posts end")

        let outputs = await stopped.outputsToTheEnd().filter { kind.matches($0.event) }
        let otherPosts = outputs.filter { runToken(of: $0.event) == stopped.otherRun.token }
        #expect(otherPosts.map(\.origin) == [stopped.otherRun.poster])
        #expect(!outputs.contains { runToken(of: $0.event) == stopped.ownRun.token })
    }

    // MARK: - Tests

    /// The production change that makes this test fail: a journal that gives
    /// the progress of another run to the event sink of the answer that
    /// `cancelAll()` stopped. That sink gives the event the mail of the
    /// stopped answer as its audience, and the output drops it.
    @Test("a run of other work that reports progress while the stopped answer winds down gives its runProgress")
    func progressOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(of: .runProgress) { run in
            let context = run.context(postingTo: run.session.outbox)
            try await run.post { await context.progress("step of \(run.token)") }
        }
    }

    /// The production change that makes this test fail: a journal that gives
    /// the message of another run to the event sink of the answer that
    /// `cancelAll()` stopped.
    @Test("a run of other work that sends a message while the stopped answer winds down gives its runMessage")
    func messageOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(of: .runMessage) { run in
            let context = run.context(postingTo: run.session.outbox)
            try await run.post { await context.message("message of \(run.token)") }
        }
    }

    /// The production change that makes this test fail: a journal that gives
    /// the question of another run to the event sink of the answer that
    /// `cancelAll()` stopped. The host then never sees the question.
    ///
    /// The close of the session ends each question, so the test waits for
    /// the wait of each run for its answer at the end.
    @Test("a run of other work that asks a question while the stopped answer winds down gives its elicitationRequested")
    func questionOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        var answers: [Task<ElicitationResponse, any Error>] = []
        try await Self.expectOnlyThePostOfOtherWork(of: .elicitationRequested) { run in
            let postings = ElicitationPostings(forwardingTo: run.session.outbox)
            let context = run.context(postingTo: postings)
            let request = PendingElicitationFixtures.formRequest(elicitationId: ULID.generate())
            try await run.post {
                answers.append(Task { try await context.elicit(request) })
            }
            try await postings.waitForPosts(Self.questionPosts)
        }
        for answer in answers {
            #expect(try await answer.value == PendingElicitationFixtures.runCancelled)
        }
    }

    /// The production change that makes this test fail: a journal that gives
    /// the terminal of another run, which settles by itself, to the event
    /// sink of the answer that `cancelAll()` stopped.
    ///
    /// The bodies of the runs report their terminals to the session when
    /// they end, so the test waits for the bodies
    /// (`RunPlane.joinRunBodies()`).
    @Test("a run of other work that settles while the stopped answer winds down gives its runSettled")
    func terminalOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(
            of: .runSettled, posting: { run in await run.gate.open() },
            thenWaiting: { stopped in try await stopped.fixture.sessionActor().runPlane.joinRunBodies() })
    }

    /// The production change that makes this test fail: a session that gives
    /// the invocation record of another run to the event sink of the answer
    /// that `cancelAll()` stopped.
    @Test("a run of other work that closes a tool call while the stopped answer winds down gives its toolInvocation")
    func invocationOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(of: .toolInvocation) { run in
            let record = ToolInvocationRecord(
                tool: FakeRun.tool, op: FakeRun.op, correlationID: run.token, sessionID: run.session.id,
                openedAt: Date(), closedAt: Date())
            try await run.post { await run.session.outbox.post(invocation: record) }
        }
    }

    /// The production change that makes this test fail: a session that gives
    /// the tool call report of another run to the event sink of the answer
    /// that `cancelAll()` stopped.
    @Test("a run of other work that reports a tool call while the stopped answer winds down gives its toolCallReport")
    func reportOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(of: .toolCallReport) { run in
            let report = ToolCallReport(
                tool: FakeRun.tool, op: FakeRun.op, correlationID: run.token, sessionID: run.session.id,
                attachments: [MountFixtures.firstAttachment])
            try await run.post { await run.session.outbox.post(report: report) }
        }
    }

    /// The production change that makes this test fail: a session that gives
    /// the display event of another run to the event sink of the answer that
    /// `cancelAll()` stopped.
    @Test("a run of other work that sends display output while the stopped answer winds down gives its toolDisplay")
    func displayOfOtherWorkWhileTheStoppedAnswerWindsDown() async throws {
        try await Self.expectOnlyThePostOfOtherWork(of: .toolDisplay) { run in
            let context = run.context(postingTo: run.session.outbox)
            try await run.post { await context.emit(chunk: .text("output of \(run.token)")) }
        }
    }
}
