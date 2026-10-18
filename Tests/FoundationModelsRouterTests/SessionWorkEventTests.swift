import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^5kbfsyv: the work events of a session.
/// ``SessionEvent/workStarted`` comes when the session gets work while it had
/// none, and ``SessionEvent/workEnded`` comes when the session has no work any
/// more, by the rules of ``RoutedSession/awaitIdle()``. Both have the origin
/// ``Origin/system``, and both come in order with the other outputs of
/// ``RoutedSession/streamSessionEvents()``. A background run that waits only
/// for the user is no work.
///
/// Everything runs against the scripted ``BackgroundingBackend`` and real
/// background tools of the session, so the suite needs no network and no
/// GPU. The tests read the order of the outputs, not a clock.
///
/// Each test fixes the order of the work that runs at the same time. A gate
/// holds each run until the test has run one check of the work end after the
/// end of the pump (``checkWorkEndAfterThePump(of:)``). Thus a work-end event
/// that comes while a run is open comes before each later output of the run,
/// in each run of the test.
@Suite("A session sends one event when its work starts and one when its work ends")
struct SessionWorkEventTests {
    // MARK: - Fixtures

    /// A background tool whose run asks the user one question through
    /// `ToolContext.elicit(_:)`, and then returns. The run is open while the
    /// question is open, and it waits only for the user.
    ///
    /// Two gates fix the order of the run: the run asks its question only
    /// after ``askGate`` opens, and it returns only after ``returnGate``
    /// opens.
    struct AskingTool: Tool, BackgroundTool {
        let name = "asking_job"
        let description = "test-only background tool whose run asks the user one question"

        /// Whether the question is a URL-mode question. Else it is a
        /// form-mode question.
        let asksForURL: Bool

        /// The gate that the run waits on before it asks its question.
        let askGate: RunLatch

        /// The gate that the run waits on after the answer, before it
        /// returns.
        let returnGate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { return SessionWorkEventTests.noContextOutput }
            let request =
                asksForURL
                ? ElicitationRequest(
                    message: "Open the page", elicitationId: ULID.generate(), url: SessionWorkEventTests.approvalURL)
                : MountFixtures.proceedRequest()
            await askGate.waitUntilOpen()
            let response = try await context.elicit(request)
            await returnGate.waitUntilOpen()
            return "answered: \(response.action.rawValue)"
        }
    }

    // MARK: - Constants

    /// The output of a latched background run.
    private static let runOutput = "the job is done"

    /// The output of ``AskingTool`` when no tool context is bound. A test
    /// never sees it.
    static let noContextOutput = "no context"

    /// The page of the URL-mode question of ``AskingTool``.
    static let approvalURL = URL(filePath: "/approve")

    /// The prompt of each caller message.
    private static let jobPrompt = "run the job"

    /// The answers of one caller message that starts a run whose terminal
    /// starts one more answer.
    private static let answersWithAMailAnswer = 2

    /// The work events of two pieces of work, one after the other.
    private static let twoChanges: [SessionEvent] = [.workStarted, .workEnded, .workStarted, .workEnded]

    // MARK: - Helpers

    /// Makes a session with `tools` over a ``BackgroundingBackend``.
    ///
    /// - Parameter tools: The tools of the session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(tools: [any Tool]) async throws -> BackgroundingSessionFixture {
        try await BackgroundingSessionFixture.make(prefix: "SessionWorkEventTests", tools: tools)
    }

    /// Reads `feed` up to and including the next output whose event `isLast`
    /// accepts.
    ///
    /// - Parameters:
    ///   - feed: The iterator of a feed of the session.
    ///   - isLast: The test of the event of the last output to read.
    /// - Returns: Each output read, in order. The last output is the output
    ///   that `isLast` accepts, unless the feed finished first.
    static func outputs(
        from feed: inout AsyncStream<SessionOutput>.Iterator, through isLast: (SessionEvent) -> Bool
    ) async -> [SessionOutput] {
        var read: [SessionOutput] = []
        while let output = await feed.next() {
            read.append(output)
            if isLast(output.event) {
                break
            }
        }
        return read
    }

    /// Reads `feed` up to and including the next ``SessionEvent/workEnded``.
    ///
    /// - Parameter feed: The iterator of a feed of the session.
    /// - Returns: Each output read, in order. The last output is the work-end
    ///   event, unless the feed finished first.
    static func outputs(throughNextWorkEnd feed: inout AsyncStream<SessionOutput>.Iterator) async
        -> [SessionOutput]
    {
        // Rule T1 quiet state: a session that stays work sends no work end, and its feed does not end, so this read hangs.
        await outputs(from: &feed, through: { $0 == .workEnded })
    }

    /// Reads `feed` until it finishes. ``RoutedSession/close()`` finishes it.
    ///
    /// - Parameter feed: The iterator of a feed of the session.
    /// - Returns: Each output read, in order.
    static func remainingOutputs(of feed: inout AsyncStream<SessionOutput>.Iterator) async -> [SessionOutput] {
        await outputs(from: &feed, through: { _ in false })
    }

    /// The work events of `outputs`, in order.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: Each ``SessionEvent/workStarted`` and
    ///   ``SessionEvent/workEnded`` event.
    static func workEvents(of outputs: [SessionOutput]) -> [SessionEvent] {
        outputs.map(\.event).filter(\.isWorkEvent)
    }

    /// The id of the question in the first ``SessionEvent/elicitationRequested(_:)``
    /// of `outputs`.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The id, in the string form that
    ///   ``RoutedSession/respond(elicitationId:response:)`` takes.
    /// - Throws: When `outputs` holds no question.
    private static func questionId(in outputs: [SessionOutput]) throws -> String {
        try #require(try firstQuestion(in: outputs).elicitation).elicitationId.description
    }

    /// Waits until the pump of `session` ended, and then runs one check of
    /// the work end of the session (``RoutedSessionActor/reportWorkEndIfNoWork()``)
    /// to its end.
    ///
    /// The pump clears its task before it reports its change of the work, and
    /// that report signals ``RoutedSessionActor/idleChanges``. So the wait
    /// sees each end of the pump. The check then runs while each run that the
    /// test holds at a gate is open, and it ends before the test opens that
    /// gate. A session that sends ``SessionEvent/workEnded`` while a run is
    /// open sends it in this check at the latest, so the event comes before
    /// each later output of that run, in each run of the test.
    ///
    /// - Parameter session: The session.
    /// - Throws: ``ConditionNeverHeld`` when the test was cancelled before the
    ///   pump ended.
    static func checkWorkEndAfterThePump(of session: RoutedSessionActor) async throws {
        try await session.idleChanges.wait(until: { await !session.isPumpRunning })
        await session.reportWorkEndIfNoWork()
    }

    /// Sends ``jobPrompt`` to a session with one ``AskingTool``, and reads the
    /// outputs up to the work end that the question of the run gives.
    ///
    /// The run asks its question only after the end of the pump of the
    /// answer and one check of the work end
    /// (``checkWorkEndAfterThePump(of:)``). Thus the end of the pump and the
    /// journal of the question come in this order, in each run of the test.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose session has the tool.
    ///   - askGate: The ``AskingTool/askGate`` of the tool.
    ///   - feed: The iterator of a feed of the session.
    /// - Returns: The outputs up to and including the work-end event.
    /// - Throws: What the respond throws, or ``ConditionNeverHeld``.
    static func outputsUpToTheQuestion(
        of fixture: BackgroundingSessionFixture, askGate: RunLatch, feed: inout AsyncStream<SessionOutput>.Iterator
    ) async throws -> [SessionOutput] {
        _ = try await fixture.session.respond(to: jobPrompt)
        try await checkWorkEndAfterThePump(of: fixture.sessionActor())
        await askGate.open()
        return await outputs(throughNextWorkEnd: &feed)
    }

    // MARK: - Tests

    @Test("a prompt gives the work-start event before the first output of its answer, and the work-end event after its answer")
    func aPromptGivesBothEventsAroundItsAnswer() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(outputs.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(outputs.last == SessionOutput(origin: .system, event: .workEnded))
        let answered = try position(ofFirst: .answered, in: outputs)
        #expect(answered == outputs.count - 2)
    }

    /// The production change that makes this test fail: a check of the work
    /// end that does not read the open runs. The end of the pump of the
    /// first answer then sends ``SessionEvent/workEnded`` while the run is
    /// open, before the gate of the run opens, so before its settlement.
    @Test("the work-end event comes after the outputs of a background run and of the answer that its terminal starts")
    func theWorkEndComesAfterTheRunOutputs() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)])
        defer { await fixture.end(opening: [gate]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        try await Self.checkWorkEndAfterThePump(of: fixture.sessionActor())
        await gate.open()
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        let settled = try position(ofFirst: .runSettled, in: outputs)
        #expect(settled < outputs.count - 1)
        #expect(outputs.map(\.event).answers.count == Self.answersWithAMailAnswer)
    }

    @Test("each change of the work gives one event: two prompts one after the other give two pairs, and close gives none")
    func eachChangeGivesOneEvent() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let first = await Self.outputs(throughNextWorkEnd: &feed)
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let second = await Self.outputs(throughNextWorkEnd: &feed)
        await fixture.session.close()
        let rest = await Self.remainingOutputs(of: &feed)

        let outputs = first + second + rest
        #expect(Self.workEvents(of: outputs) == Self.twoChanges)
        #expect(outputs.filter(\.event.isWorkEvent).allSatisfy { $0.origin == .system })
    }

    @Test("a requested compaction is work: its events come between the work-start and the work-end events")
    func aRequestedCompactionIsWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        fixture.session.compact(prompt: .default, budget: nil)
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(outputs.first?.event == .workStarted)
        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        let started = try position(ofFirst: .compactionStarted, in: outputs)
        #expect(started > 0)
        let ended = try position(ofFirst: .compaction, .compactionFailed, in: outputs)
        #expect(ended < outputs.count - 1)
    }

    /// The production change that makes this test fail: a check of the work
    /// end that counts a run with an open question as no work before the
    /// journal recorded the question (no read of
    /// ``RoutedSessionActor/askedQuestions``). The test holds the question
    /// back from the journal while a check runs, so that check then sends
    /// ``SessionEvent/workEnded`` before ``SessionEvent/elicitationRequested(_:)``.
    @Test("a run that waits only for the user gives the work-end event after its question, and isIdle() says idle while a pending operation stays")
    func aRunThatWaitsOnlyForTheUserIsNoWork() async throws {
        let fixture = try await Self.makeFixture(tools: [])
        let runGate = RunLatch()
        defer { await fixture.end(opening: [runGate]) }
        let session = try fixture.sessionActor()
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let token = await trackFakeRun(on: session.runPlane, latch: runGate)
        // The run asks its question. The question is open on the run plane,
        // and the postings keep it back from the journal of the session.
        let postings = ElicitationPostings()
        let context = PendingElicitationFixtures.makeContext(
            for: fixture.session, postingTo: postings, completionToken: token)
        let questionId = ULID.generate()
        let answering = Task {
            try await context.elicit(PendingElicitationFixtures.formRequest(elicitationId: questionId))
        }
        // The wait also ends when the question ended (rule T1): no answer
        // comes before the decline at the end of the test.
        try await postings.waitForPosts(1, endingOnEndOf: answering)

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        try await Self.checkWorkEndAfterThePump(of: session)
        #expect(await session.isIdle() == false)
        await fixture.session.outbox.post(event: try #require(postings.postedEvents.first))
        let outputs = await Self.outputs(throughNextWorkEnd: &feed)

        let asked = try position(ofFirst: .elicitationRequested, in: outputs)
        #expect(asked < outputs.count - 1)
        #expect(Self.workEvents(of: outputs) == [.workStarted, .workEnded])
        #expect(await session.runPlane.runsWaitingOnlyForUser().count == 1)
        #expect(await session.isIdle())
        #expect(await session.hasPendingOperation())
        // Rule T1 quiet state: a session that counts the run of the user as work hangs here, and no event comes after it.
        #expect(await fixture.session.awaitIdle())
        _ = await fixture.session.respond(elicitationId: questionId.description, response: .decline)
        #expect(try await answering.value == .decline)
    }

    /// The production change that makes this test fail: a check of the work
    /// end that does not read the open runs. The end of the pump of the
    /// answer to the elicitation mail then sends ``SessionEvent/workEnded``
    /// while the resumed run is held open, before its settlement.
    @Test("an answer to the question of a run that waits only for the user gives the work-start event before each output of the resumed run")
    func anAnswerStartsWorkBeforeTheResumedRun() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        defer { await fixture.end(opening: [askGate, returnGate]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let asking = try await Self.outputsUpToTheQuestion(of: fixture, askGate: askGate, feed: &feed)

        let delivery = await fixture.session.respond(
            elicitationId: try Self.questionId(in: asking), response: .decline)
        // An answer that was not delivered starts no answer, and the read
        // below then waits on: the test fails here, before it waits (rule T1).
        try #require(delivery == .delivered)
        // The answer goes to the session as mail, and that mail starts an
        // answer while the resumed run waits at its return gate.
        let beforeReturn = await Self.outputs(from: &feed, through: SessionEventCase.answered.matches)
        try await Self.checkWorkEndAfterThePump(of: fixture.sessionActor())
        await returnGate.open()
        let resumed = beforeReturn + (await Self.outputs(throughNextWorkEnd: &feed))

        #expect(resumed.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(Self.workEvents(of: resumed) == [.workStarted, .workEnded])
        let settled = try position(ofFirst: .runSettled, in: resumed)
        #expect(settled < resumed.count - 1)
    }

    /// The production change that makes this test fail: a check of the work
    /// end that does not read the open runs. A check after the completion
    /// then sends ``SessionEvent/workEnded`` while the resumed run is held
    /// open, before its settlement.
    @Test("an accept of a URL question gives no work event, and its completion starts the work of the resumed run")
    func aURLAcceptIsNoWorkAndItsCompletionIs() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [AskingTool(asksForURL: true, askGate: askGate, returnGate: returnGate)])
        defer { await fixture.end(opening: [askGate, returnGate]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let asking = try await Self.outputsUpToTheQuestion(of: fixture, askGate: askGate, feed: &feed)
        let questionId = try Self.questionId(in: asking)

        let accepted = await fixture.session.respond(elicitationId: questionId, response: .accept(content: nil))
        let completed = await fixture.session.complete(elicitationId: questionId)
        // A question with no completion does not resume its run, and the read
        // below then waits on: the test fails here, before it waits (rule T1).
        try #require(completed == .completed)
        try await Self.checkWorkEndAfterThePump(of: fixture.sessionActor())
        await returnGate.open()
        let resumed = await Self.outputs(throughNextWorkEnd: &feed)

        #expect(accepted == .acceptedAwaitingCompletion)
        #expect(resumed.first == SessionOutput(origin: .system, event: .workStarted))
        #expect(Self.workEvents(of: resumed) == [.workStarted, .workEnded])
        let settled = try position(ofFirst: .runSettled, in: resumed)
        #expect(settled < resumed.count - 1)
    }
}
