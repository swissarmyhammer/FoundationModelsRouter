import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^fqb5rjr: ``SessionEvent/elicitationEnded(_:)``. The
/// session sends it when a question of a run ends with no answer of the
/// client, and never for a question that the client answered.
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

    /// The ids of the mail of `origin`.
    ///
    /// - Parameter origin: The origin of one output.
    /// - Returns: The ids for ``Origin/mail(_:)``, or `nil` for another
    ///   origin.
    private static func mailIds(of origin: Origin) -> Set<MailID>? {
        guard case .mail(let ids) = origin else { return nil }
        return ids
    }

    // MARK: - Tests

    /// The production change that makes this test fail: a run journal that
    /// sends no end when the terminal of a cancelled run arrives.
    @Test("a cancel of the run gives the end with the origin of the run mail, before the runSettled and the answer of that mail")
    func aRunCancelGivesTheEndBeforeTheTerminalOfTheRunMail() async throws {
        var asked = try await Self.askQuestion()

        _ = try await asked.fixture.sessionActor().runPlane.cancel(completionToken: asked.question.correlationID)
        let outputs = await SessionWorkEventTests.outputs(throughNextWorkEnd: &asked.feed)

        let end = try Self.soleEnd(in: outputs, of: asked)
        let settled = try position(ofFirst: .runSettled, in: outputs)
        #expect(outputs[settled].origin == end.origin)
        #expect(end.position < settled)
        let ids = try #require(Self.mailIds(of: end.origin), "the end has the origin \(end.origin), not the run mail")
        let answered = try #require(
            firstPosition(in: outputs) { event in
                guard case .answered(let answer) = event else { return false }
                return !ids.isDisjoint(with: answer.mailIds)
            })
        #expect(end.position < answered)
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
        await asked.end()
    }

    /// The production change that makes this test fail: an end check that
    /// does not know which questions the client answered.
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

/// Exercises the record of the questions (``AskedQuestions``) that decides
/// when a question ended with no answer of the client. An answer of the
/// client can be on its way to the run plane while the run plane ends the
/// question, so these cases cannot be fixed in order through a session.
@Suite("The record of the questions finds each question that ended with no answer of the client")
struct AskedQuestionsEndTests {
    /// The token of the run that asks each question.
    private static let runToken = "run-token"

    /// The token of another run.
    private static let otherRunToken = "other-run-token"

    /// A record with one form-mode question of ``runToken``.
    ///
    /// - Returns: The record and the id of the question.
    private static func recordWithOneQuestion() -> (questions: AskedQuestions, id: ULID) {
        var questions = AskedQuestions()
        let request = MountFixtures.proceedRequest()
        questions.noteAsked(request, runToken: runToken)
        return (questions, request.elicitationId)
    }

    @Test("a question that left the run plane ends one time, and only for its own run")
    func aQuestionThatLeftEndsOneTime() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let otherRun = questions.endQuestions(ofRun: Self.otherRunToken, notIn: [], at: .system)
        let stillOpen = questions.endQuestions(ofRun: Self.runToken, notIn: [id], at: .system)
        let left = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: .system)
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: .system)
        let lateAnswer = questions.beginAnswer(to: id)

        #expect(otherRun.isEmpty)
        #expect(stillOpen.isEmpty)
        #expect(left == [id])
        #expect(again.isEmpty)
        #expect(lateAnswer == false)
    }

    @Test("a question with an answer on its way ends at that answer when the run plane had no question for it")
    func anAnswerOnItsWayDefersTheEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record
        let origin = Origin.signal(SignalID())

        let answerBegan = questions.beginAnswer(to: id)
        let deferred = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: origin)
        let endOrigin = questions.noteAnswered(id, outcome: .noQuestion)
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: .system)

        #expect(answerBegan)
        #expect(deferred.isEmpty)
        #expect(endOrigin == origin)
        #expect(again.isEmpty)
    }

    @Test("a question with an answer on its way gives no end when that answer resumed the run")
    func anAnswerThatResumedTheRunGivesNoEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let answerBegan = questions.beginAnswer(to: id)
        let deferred = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: .system)
        let endOrigin = questions.noteAnswered(id, outcome: .resumedRun)
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], at: .system)

        #expect(answerBegan)
        #expect(deferred.isEmpty)
        #expect(endOrigin == nil)
        #expect(again.isEmpty)
    }
}
