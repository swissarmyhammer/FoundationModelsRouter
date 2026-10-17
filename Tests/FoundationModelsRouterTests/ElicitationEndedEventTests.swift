import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^fqb5rjr: ``SessionEvent/elicitationEnded(_:)``. The
/// session sends it when a cancel of the run plane ends a question of a run
/// with no answer of the client, and never for a question that the client
/// answered. The run plane decides and posts each end (task ^pjycptw).
///
/// Each test fixes the order of the work: the run of
/// ``SessionWorkEventTests/AskingTool`` asks its question only after the
/// first answer ended, and the test reads the feed up to the work-end event
/// that the question gives
/// (``SessionWorkEventTests/outputsUpToTheQuestion(of:askGate:feed:)``). Thus
/// the session recorded the question before the test ends it. The return gate
/// of the tool is open from the start, so the run returns as soon as its
/// question ends. The tests read the order of the outputs, not a clock.
///
/// Other tests ask the question inside an answer (task ^vkkecjt): the
/// session runs the call of ``InAnswerURLAskingTool`` to completion inside
/// the answer to a prompt, and the test reads the feed up to the question.
/// The answer then waits on the question, so the test ends the question while
/// the answer runs.
@Suite("A question of a run that ends with no answer of the client gives one elicitationEnded event")
struct ElicitationEndedEventTests {
    // MARK: - Fixtures

    /// A tool with no background declaration: the session runs its call to
    /// completion inside the answer that calls it. The call asks one URL-mode
    /// question through `ToolContext.elicit(_:)`, and then returns the action
    /// of the answer. This is the shape of a runCode call whose MCP tool asks
    /// a URL-mode question.
    struct InAnswerURLAskingTool: Tool {
        let name = "in_answer_url_asking_tool"
        let description = "test-only tool that asks one URL-mode question inside the answer that calls it"

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { return SessionWorkEventTests.noContextOutput }
            let response = try await context.elicit(ElicitationCompletedEventTests.urlRequest(ULID.generate()))
            return "answered: \(response.action.rawValue)"
        }
    }

    // MARK: - Constants

    /// The prefix of the directory of each session.
    private static let prefix = "ElicitationEndedEventTests"

    /// The prompt whose answer calls ``InAnswerURLAskingTool``.
    private static let askingPrompt = "ask inside the answer"

    /// The count of a post or an end that comes one time.
    fileprivate static let once = 1

    // MARK: - Helpers

    /// One session whose tool waits on an open question, and a feed that read
    /// up to the question.
    private struct AskedQuestion {
        /// The fixture of the session.
        let fixture: BackgroundingSessionFixture

        /// The feed of the session, after the outputs up to the question.
        var feed: AsyncStream<SessionOutput>.Iterator

        /// The `.elicitation` event of the question.
        let question: OperationEvent

        /// The gates of the tool, opened at the end of the test.
        let gates: [RunLatch]

        /// The id of the question.
        var questionId: ULID {
            get throws { try #require(question.elicitation).elicitationId }
        }

        /// Ends the fixture: opens the gates, closes the session and removes
        /// the directory.
        func end() async {
            await fixture.end(opening: gates)
        }
    }

    /// A question that a tool asks inside the answer to a prompt, and the id
    /// of the mail of that prompt.
    private struct QuestionInsideAnAnswer {
        /// The question. The answer to the prompt waits on it.
        var asked: AskedQuestion

        /// The id of the mail of the prompt.
        let promptMail: MailID
    }

    /// Makes a session with one ``SessionWorkEventTests/AskingTool`` whose
    /// return gate is open, and reads its feed up to the question of the run.
    ///
    /// When this helper throws, it ends the fixture first, and opens the
    /// ask gate of the tool (rule T1).
    ///
    /// - Returns: The session, its feed and the question.
    /// - Throws: What the fixture or the first answer throws.
    private static func askQuestion() async throws -> AskedQuestion {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        await returnGate.open()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: prefix,
            tools: [SessionWorkEventTests.AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        do {
            var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
            let asking = try await SessionWorkEventTests.outputsUpToTheQuestion(
                of: fixture, askGate: askGate, feed: &feed)
            return AskedQuestion(
                fixture: fixture, feed: feed, question: try firstQuestion(in: asking), gates: [askGate])
        } catch {
            await fixture.end(opening: [askGate])
            throw error
        }
    }

    /// Makes a session with one ``InAnswerURLAskingTool``, mails
    /// ``askingPrompt``, and reads the feed up to the question that the tool
    /// asks inside the answer to that prompt. The answer then runs, and its
    /// tool waits on the question.
    ///
    /// The read also ends at the end of the answer (rule T1): in a test that
    /// passes, the answer waits on the question, so the answer cannot end
    /// before the question. An answer that ended with no question gives a
    /// read with no question, and ``firstQuestion(in:)`` fails the test. When
    /// this helper throws, it ends the fixture first.
    ///
    /// - Returns: The question and the id of the prompt mail.
    /// - Throws: What the fixture throws, or when the feed has no question.
    private static func askQuestionInsideAnAnswer() async throws -> QuestionInsideAnAnswer {
        let fixture = try await BackgroundingSessionFixture.make(prefix: prefix, tools: [InAnswerURLAskingTool()])
        do {
            var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
            let prompt = try fixture.sessionActor().mail(
                RoutedSessionActor.userMessage(askingPrompt, maxTokens: nil, mode: .reply))
            let asking = await SessionWorkEventTests.outputs(
                from: &feed, through: { SessionEventCase.elicitationRequested.matches($0) || $0.isAnswerEnd })
            let asked = AskedQuestion(fixture: fixture, feed: feed, question: try firstQuestion(in: asking), gates: [])
            return QuestionInsideAnAnswer(asked: asked, promptMail: prompt.id)
        } catch {
            await fixture.end()
            throw error
        }
    }

    /// Checks that the session takes no answer and no completion to the
    /// question any more: each gives `.noPendingElicitation`.
    ///
    /// - Parameter asked: The question, after it ended with no answer of the
    ///   client.
    /// - Throws: When the question has no id.
    private static func expectNoPendingQuestion(_ asked: AskedQuestion) async throws {
        let id = try asked.questionId.description
        #expect(await asked.fixture.session.respond(elicitationId: id, response: .decline) == .noPendingElicitation)
        #expect(await asked.fixture.session.complete(elicitationId: id) == .noPendingElicitation)
    }

    // MARK: - Tests

    /// The production change that makes this test fail: a session whose
    /// outbox drops the end that the run plane posts at a cancel of the run,
    /// or a journal that gives the end the origin of the run mail of the
    /// question in place of the origin of the work that cancelled the run.
    @Test("a cancel of the run gives the end with the origin of the work that cancelled it, before the runSettled")
    func aRunCancelGivesTheEndWithTheOriginOfTheCancelBeforeTheTerminal() async throws {
        var asked = try await Self.askQuestion()
        defer { await asked.end() }
        let session = try asked.fixture.sessionActor()
        let cancelling = Origin.mail([MailID()])

        let token = asked.question.correlationID
        _ = await OriginContext.$current.withValue(cancelling) {
            await session.runPlane.cancel(completionToken: token)
        }
        let outputs = await SessionWorkEventTests.outputs(throughNextWorkEnd: &asked.feed)

        let end = try PendingElicitationFixtures.soleEnd(in: outputs, of: try asked.questionId)
        #expect(end.origin == cancelling)
        #expect(end.position < (try position(ofFirst: .runSettled, in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
    }

    /// The production change that makes this test fail: a `cancelAll()` that
    /// leaves the end of the question to the sweep, which runs after the
    /// `signalDone` of the signal.
    @Test("cancelAll() gives the end with the origin of its signal, before the signalDone of that signal")
    func cancelAllGivesTheEndBeforeItsSignalDone() async throws {
        var asked = try await Self.askQuestion()
        defer { await asked.end() }

        let signal = asked.fixture.session.cancelAll()
        let outputs = await SessionWorkEventTests.outputs(from: &asked.feed, through: { $0 == .signalDone(signal) })

        let end = try PendingElicitationFixtures.soleEnd(in: outputs, of: try asked.questionId)
        #expect(end.origin == .signal(signal))
        #expect(end.position < (try position(of: .signalDone(signal), in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
    }

    /// The production change that makes this test fail: a `close()` that
    /// leaves the end of the question to the sweep, which runs after the end
    /// of the feeds.
    @Test("close() gives the end with the origin system, before the feed ends")
    func closeGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestion()
        defer { await asked.end() }

        await asked.fixture.session.close()
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        let end = try PendingElicitationFixtures.soleEnd(in: outputs, of: try asked.questionId)
        #expect(end.origin == .system)
        try await Self.expectNoPendingQuestion(asked)
    }

    /// The production change that makes this test fail: a session that sends
    /// an end for a question that the client answered.
    @Test("a question that the client answered gives no end, also when the session closes later")
    func anAnsweredQuestionGivesNoEnd() async throws {
        var asked = try await Self.askQuestion()
        defer { await asked.end() }

        let delivery = await asked.fixture.session.respond(
            elicitationId: try asked.questionId.description, response: .decline)
        // A question that the session does not take gives no more work, and
        // the read then waits on: the test fails here, before it reads (rule
        // T1).
        try #require(delivery == .delivered)
        let resumed = await SessionWorkEventTests.outputs(throughNextWorkEnd: &asked.feed)
        await asked.fixture.session.close()
        let rest = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        #expect(PendingElicitationFixtures.ends(in: resumed + rest).isEmpty)
    }

    /// The production change that makes this test fail: a journal that gives
    /// the end to the event sink of the answer that `cancelAll()` stopped.
    /// That answer continues until its tool gets the cancel, and the output
    /// drops each event for the mail of a stopped answer, so the end does not
    /// come.
    @Test("cancelAll() during an answer whose tool waits on a question gives the end before signalDone")
    func cancelAllDuringAnAnswerGivesTheEndBeforeItsSignalDone() async throws {
        let inside = try await Self.askQuestionInsideAnAnswer()
        var asked = inside.asked
        defer { await asked.end() }

        let signal = asked.fixture.session.cancelAll()
        let outputs = await SessionWorkEventTests.outputs(from: &asked.feed, through: { $0 == .signalDone(signal) })

        let failure = AnswerFailure(mailIds: [inside.promptMail], reason: .cancelled)
        let failed = try position(of: .answerFailed(failure), in: outputs)
        let end = try PendingElicitationFixtures.soleEnd(in: outputs, of: try asked.questionId)
        #expect(end.origin == .signal(signal))
        #expect(failed < end.position)
        #expect(end.position < (try position(of: .signalDone(signal), in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
    }

    /// The production change that makes this test fail: a journal that drops
    /// the end that `close()` gives to a question inside the answer that
    /// runs, or a `close()` that ends the feeds before that end.
    @Test("close() during an answer whose tool waits on a question gives the end with the origin system, before the feed ends")
    func closeDuringAnAnswerGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestionInsideAnAnswer().asked
        defer { await asked.end() }

        await asked.fixture.session.close()
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        let end = try PendingElicitationFixtures.soleEnd(in: outputs, of: try asked.questionId)
        #expect(end.origin == .system)
        try await Self.expectNoPendingQuestion(asked)
    }

    /// The production change that makes this test fail: a `close()` that
    /// ends the feeds while a question that a run asked during the stop of
    /// all work (``RoutedSessionActor/performCancelAll()``) is still open, so
    /// the end of that question goes to a feed that ended (rule R3).
    ///
    /// The first question holds the stop: its end post waits at a gate, so
    /// `RunPlane.cancelOpenElicitations()` of the stop waits. In that window
    /// a second question opens, as the relayed question of a subagent does,
    /// and the session sends it on the feed. Its run is no background run, so
    /// no cancel of a run ends it. The sweep that the stop starts holds at the
    /// slow canceler of a run, so the sweep does not end the second question
    /// before the feed ends. The test opens that canceler only after it read
    /// the feed to its end.
    @Test("close() ends a question that opens while its stop waits, on the feed, before the feed ends")
    func closeEndsAQuestionThatOpensWhileItsStopWaits() async throws {
        let firstEnd = RunLatch()
        let slowCanceler = CancelerHold()
        let fixture = try await BackgroundingSessionFixture.make(prefix: Self.prefix, tools: [])
        try await fixture.endingAfter(opening: [firstEnd, slowCanceler.release]) {
            let session = try fixture.sessionActor()
            await session.attachOutboxJournalIfNeeded()
            var feed = await session.streamSessionEvents().makeAsyncIterator()
            let heldRun = await trackFakeRun(
                on: session.runPlane, latch: slowCanceler.release, kind: .process, holdingCancelerAt: slowCanceler)
            let first = ContextQuestion(on: session, runToken: heldRun, holdingEndsAt: firstEnd)
            let firstAnswer = Task { try await first.ask() }
            try await first.waitForThePost()

            let closing = Task { await session.close() }
            try await first.waitForTheEndPost()
            let second = ContextQuestion(on: session, runToken: RunPlane.makeCompletionToken())
            let secondAnswer = Task { try await second.ask() }
            try await second.waitForThePost()
            await firstEnd.open()
            let outputs = await SessionWorkEventTests.remainingOutputs(of: &feed)
            await slowCanceler.release.open()
            await closing.value
            let answers = [try await firstAnswer.value, try await secondAnswer.value]

            let asked = try #require(firstPosition(in: outputs, where: isQuestion(second.id)))
            let ends = PendingElicitationFixtures.ends(in: outputs).filter { $0.end.elicitationId == second.id }
            #expect(ends.count == Self.once, "the feed ended while the second question was open")
            let end = try #require(ends.first)
            #expect(end.end == ElicitationEnd(elicitationId: second.id, response: PendingElicitationFixtures.runCancelled))
            #expect(end.origin == .system)
            #expect(asked < end.position)
            #expect(answers == [PendingElicitationFixtures.runCancelled, PendingElicitationFixtures.runCancelled])
        }
    }
}

/// A question that a test asks through a context of its own over the run
/// plane of a session (``PendingElicitationFixtures/makeContext(for:postingTo:completionToken:)``).
///
/// The sink of the context forwards each post to the journal of the
/// session. ``ask()`` signals the changes of that sink when the question
/// settles, so each wait of this type for a post also ends when the question
/// settled with no such post.
private final class ContextQuestion: Sendable {
    /// The id of the question.
    let id = ULID.generate()

    /// The sink of the context. It forwards each post to the session.
    let postings: ElicitationPostings

    /// The context that asks the question.
    private let context: ToolContext

    /// Whether ``ask()`` returned or threw.
    private let settled = Mutex(false)

    /// Makes the question and its context. The question is not asked yet.
    ///
    /// - Parameters:
    ///   - session: The session whose run plane and journal the context uses.
    ///   - runToken: The token of the run that asks.
    ///   - endGate: The gate that holds the end post of the question before
    ///     it goes to the session, or `nil` for no gate.
    init(on session: RoutedSessionActor, runToken: String, holdingEndsAt endGate: RunLatch? = nil) {
        postings = ElicitationPostings(forwardingTo: session.outbox, holdingEndsAt: endGate)
        context = PendingElicitationFixtures.makeContext(for: session, postingTo: postings, completionToken: runToken)
    }

    /// Asks the question, and waits for its answer.
    ///
    /// - Returns: The answer that the run gets.
    /// - Throws: What `ToolContext.elicit(_:)` throws.
    func ask() async throws -> ElicitationResponse {
        defer {
            settled.withLock { $0 = true }
            postings.changes.signal()
        }
        return try await context.elicit(PendingElicitationFixtures.formRequest(elicitationId: id))
    }

    /// Waits until the journal of the session recorded the question, and
    /// checks that it did.
    ///
    /// - Throws: When the question settled with no post, or
    ///   ``ConditionNeverHeld``.
    func waitForThePost() async throws {
        try await waitUntilSettledOr { postings.postCount >= ElicitationEndedEventTests.once }
        try #require(postings.postCount == ElicitationEndedEventTests.once, "the question settled with no post")
    }

    /// Waits until the end post of the question came to the sink, also when
    /// the end gate holds it, and checks that it came.
    ///
    /// - Throws: When the question settled with no end post, or
    ///   ``ConditionNeverHeld``.
    func waitForTheEndPost() async throws {
        try await waitUntilSettledOr { postings.arrivedEndCount >= ElicitationEndedEventTests.once }
        try #require(postings.arrivedEndCount == ElicitationEndedEventTests.once, "the question settled with no end post")
    }

    /// Waits until `condition` holds, or until the question settled.
    ///
    /// - Parameter condition: Reads the sink.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    private func waitUntilSettledOr(_ condition: () -> Bool) async throws {
        try await postings.changes.wait(until: { condition() || settled.withLock { $0 } })
    }
}

/// Exercises the record of the questions (``AskedQuestions``), which makes
/// sure that each end and each completion that the run plane posts goes out
/// one time, and only for a question that the journal recorded.
@Suite("The record of the questions sends each end and each completion one time")
struct AskedQuestionsEndTests {
    /// A record with one question.
    ///
    /// - Parameter request: The question. The default is a form-mode
    ///   question.
    /// - Returns: The record and the id of the question.
    private static func recordWithOneQuestion(
        _ request: ElicitationRequest = MountFixtures.proceedRequest()
    ) -> (questions: AskedQuestions, id: ULID) {
        var questions = AskedQuestions()
        questions.noteAsked(request, mailID: nil)
        return (questions, request.elicitationId)
    }

    /// The production change that makes this test fail: a record that keeps
    /// a question after its end, so a second end post gives a second event.
    @Test("a recorded question ends one time, and then leaves the record")
    func aRecordedQuestionEndsOneTime() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let first = questions.end(id)
        let second = questions.end(id)

        #expect(first)
        #expect(second == false)
        #expect(questions.wasAsked(id) == false)
    }

    /// The production change that makes this test fail: a record that ends
    /// each id that the run plane posts, also an id that the journal never
    /// recorded.
    @Test("an end post for a question that the journal did not record gives no event")
    func anUnrecordedQuestionGivesNoEnd() {
        var questions = AskedQuestions()

        #expect(questions.end(ULID.generate()) == false)
    }

    /// The production change that makes this test fail: a record that says
    /// it holds no question while an end post is on its way, so a stop of the
    /// session does not wait for that post.
    @Test("the record holds a question until the journal handled its end post")
    func theRecordHoldsAQuestionUntilItsEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let before = questions.holdsQuestion(amongAnyOf: [id])
        _ = questions.end(id)
        let after = questions.holdsQuestion(amongAnyOf: [id])

        #expect(before)
        #expect(after == false)
    }

    /// The production change that makes this test fail: a record that takes
    /// an accepted URL question out when the completion of the client
    /// resumes the run, so the completion post that comes later finds no
    /// question and sends no completion.
    @Test("a completion of the client keeps the question until the completion post")
    func aCompletionOfTheClientKeepsTheQuestionUntilThePost() {
        let (record, id) = Self.recordWithOneQuestion(ElicitationCompletedEventTests.urlRequest(ULID.generate()))
        var questions = record

        questions.noteAnswered(id, outcome: .acceptedAwaitingCompletion)
        questions.noteAnswered(id, outcome: .resumedRun)
        let heldBeforeThePost = questions.holdsQuestion(amongAnyOf: [id])
        let posted = questions.complete(id, postedBy: .system)

        #expect(heldBeforeThePost)
        #expect(posted != nil)
        #expect(questions.holdsQuestion(amongAnyOf: [id]) == false)
    }
}
