import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
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
@Suite("A question of a run that ends with no answer of the client gives one elicitationEnded event")
struct ElicitationEndedEventTests {
    // MARK: - Helpers

    /// The response that the run plane gives to each question of a stopped
    /// run.
    private static let runCancelled = ElicitationResponse.cancel(reason: RunPlane.runCancelledReason)

    /// One session with one ``SessionWorkEventTests/AskingTool`` whose run
    /// waits on an open question, and a feed that read up to the question.
    private struct AskedQuestion {
        /// The fixture of the session.
        let fixture: BackgroundingSessionFixture

        /// The feed of the session, after the outputs up to the question.
        var feed: AsyncStream<SessionOutput>.Iterator

        /// The `.elicitation` event of the question.
        let question: OperationEvent

        /// The ask gate of the tool, open after the question.
        let askGate: RunLatch

        /// The id of the question.
        var questionId: ULID {
            get throws { try #require(question.elicitation).elicitationId }
        }

        /// Ends the fixture: opens the gates, closes the session and removes
        /// the directory.
        func end() async {
            await fixture.end(opening: [askGate])
        }
    }

    /// Makes a session with one ``SessionWorkEventTests/AskingTool`` whose
    /// return gate is open, and reads its feed up to the question of the run.
    ///
    /// - Returns: The session, its feed and the question.
    /// - Throws: What the fixture or the first answer throws.
    private static func askQuestion() async throws -> AskedQuestion {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        await returnGate.open()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: "ElicitationEndedEventTests",
            tools: [SessionWorkEventTests.AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        let asking = try await SessionWorkEventTests.outputsUpToTheQuestion(
            of: fixture, askGate: askGate, feed: &feed)
        return AskedQuestion(fixture: fixture, feed: feed, question: try firstQuestion(in: asking), askGate: askGate)
    }

    /// Each ``SessionEvent/elicitationEnded(_:)`` of `outputs`, with its
    /// origin and its position.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The ends, in order.
    private static func ends(in outputs: [SessionOutput]) -> [(position: Int, origin: Origin, end: ElicitationEnd)] {
        outputs.enumerated().compactMap { position, output in
            guard case .elicitationEnded(let end) = output.event else { return nil }
            return (position, output.origin, end)
        }
    }

    /// The one ``SessionEvent/elicitationEnded(_:)`` of `outputs`, checked
    /// against the question: the same id, and the cancel of a stopped run.
    ///
    /// - Parameters:
    ///   - outputs: Outputs of a session.
    ///   - asked: The question.
    /// - Returns: The position and the origin of the end.
    /// - Throws: When `outputs` does not hold exactly one end.
    private static func soleEnd(
        in outputs: [SessionOutput], of asked: AskedQuestion
    ) throws -> (position: Int, origin: Origin) {
        let ends = ends(in: outputs)
        #expect(ends.count == 1, "expected one end of the question, got \(ends.count)")
        let end = try #require(ends.first)
        #expect(end.end == ElicitationEnd(elicitationId: try asked.questionId, response: runCancelled))
        return (end.position, end.origin)
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
        let session = try asked.fixture.sessionActor()
        let cancelling = Origin.mail([MailID()])

        let token = asked.question.correlationID
        _ = await OriginContext.$current.withValue(cancelling) {
            await session.runPlane.cancel(completionToken: token)
        }
        let outputs = await SessionWorkEventTests.outputs(throughNextWorkEnd: &asked.feed)

        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(end.origin == cancelling)
        #expect(end.position < (try position(ofFirst: .runSettled, in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a `cancelAll()` that
    /// leaves the end of the question to the sweep, which runs after the
    /// `signalDone` of the signal.
    @Test("cancelAll() gives the end with the origin of its signal, before the signalDone of that signal")
    func cancelAllGivesTheEndBeforeItsSignalDone() async throws {
        var asked = try await Self.askQuestion()

        let signal = asked.fixture.session.cancelAll()
        let outputs = await SessionWorkEventTests.outputs(from: &asked.feed, through: { $0 == .signalDone(signal) })

        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(end.origin == .signal(signal))
        #expect(end.position < (try position(of: .signalDone(signal), in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a `close()` that
    /// leaves the end of the question to the sweep, which runs after the end
    /// of the feeds.
    @Test("close() gives the end with the origin system, before the feed ends")
    func closeGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestion()

        await asked.fixture.session.close()
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(end.origin == .system)
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a session that sends
    /// an end for a question that the client answered.
    @Test("a question that the client answered gives no end, also when the session closes later")
    func anAnsweredQuestionGivesNoEnd() async throws {
        var asked = try await Self.askQuestion()

        let delivery = await asked.fixture.session.respond(
            elicitationId: try asked.questionId.description, response: .decline)
        let resumed = await SessionWorkEventTests.outputs(throughNextWorkEnd: &asked.feed)
        await asked.fixture.session.close()
        let rest = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        #expect(delivery == .delivered)
        #expect(Self.ends(in: resumed + rest).isEmpty)
        await asked.end()
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
