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

    /// The position of the ``SessionEvent/answered(_:)`` of the run mail of
    /// `origin`.
    ///
    /// - Parameters:
    ///   - origin: The origin of a run event: the run mail that holds it.
    ///   - outputs: Outputs of a session.
    /// - Returns: The position.
    /// - Throws: When `origin` is not a run mail, or when `outputs` holds no
    ///   answer of that mail.
    private static func answeredPosition(ofMailOf origin: Origin, in outputs: [SessionOutput]) throws -> Int {
        let ids = try #require(mailIds(of: origin), "the origin \(origin) is not the run mail")
        return try #require(
            firstPosition(in: outputs) { event in
                guard case .answered(let answer) = event else { return false }
                return !ids.isDisjoint(with: answer.mailIds)
            })
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

    /// The step of an answer of the client where the answer waits at its
    /// gate.
    private enum AnswerHold: Equatable {
        /// Before the run plane gets the answer.
        case beforeTheRunPlane

        /// After the run plane gave its result, before the session records it.
        case afterTheRunPlane

        /// Opens `reached` and waits until `gate` opens, when `step` is this
        /// hold. Else it does nothing.
        ///
        /// - Parameters:
        ///   - step: The step that the answer is at.
        ///   - reached: The latch that tells the test that the answer waits.
        ///   - gate: The gate that holds the answer.
        func hold(at step: Self, reached: RunLatch, gate: RunLatch) async {
            guard step == self else { return }
            await reached.open()
            await gate.waitUntilOpen()
        }
    }

    /// One answer of the client that is on its way to the run plane, held at
    /// a gate.
    private struct AnswerOnItsWay {
        /// The task of the answer. It gives what the run plane did.
        let task: Task<ElicitationAnswerDelivery, Never>

        /// The gate that holds the answer.
        let gate: RunLatch
    }

    /// Starts a decline of the question through the steps of
    /// ``RoutedSession/respond(elicitationId:response:)``, and returns when
    /// the answer waits at `hold`.
    ///
    /// - Parameters:
    ///   - asked: The question.
    ///   - hold: The step where the answer waits.
    /// - Returns: The answer on its way.
    /// - Throws: When the session is not a ``RoutedSessionActor`` or the
    ///   question has no id.
    private static func startAnswer(to asked: AskedQuestion, holdingAt hold: AnswerHold) async throws
        -> AnswerOnItsWay
    {
        let session = try asked.fixture.sessionActor()
        let id = try asked.questionId.description
        let reached = RunLatch()
        let gate = RunLatch()
        let task = Task {
            await session.deliverAnswer(
                toElicitation: id, .response(.decline), orReturn: .noPendingElicitation,
                outcome: QuestionAnswerOutcome.init
            ) { id in
                await hold.hold(at: .beforeTheRunPlane, reached: reached, gate: gate)
                let delivery = await session.runPlane.respond(elicitationId: id, .decline)
                await hold.hold(at: .afterTheRunPlane, reached: reached, gate: gate)
                return delivery
            }
        }
        await reached.waitUntilOpen()
        return AnswerOnItsWay(task: task, gate: gate)
    }

    /// Waits until an end check found the question gone while the answer was
    /// on its way, so the end of the question waits for that answer.
    ///
    /// - Parameter asked: The question.
    /// - Throws: ``ConditionNeverHeld`` when the test was cancelled first.
    private static func awaitDeferredEnd(of asked: AskedQuestion) async throws {
        let session = try asked.fixture.sessionActor()
        let id = try asked.questionId
        try await session.stateChanges.wait(until: { await session.askedQuestions.hasDeferredEnd(of: id) })
    }

    /// The count of the waits for an answer on its way when ``RoutedSession/close()``
    /// waits for the answer too: the wait of the end check that held the end
    /// of the question first, and the wait of close.
    private static let closeAndTheOwnerOfTheEndWait = 2

    /// Closes the session while an earlier end check (a cancel of the run or
    /// a ``RoutedSession/cancelAll()`` signal) holds the end of the question
    /// for `answer`, and reads the feed to its end.
    ///
    /// The gate of `answer` opens only when close waits for the answer too
    /// (``RoutedSessionActor/questionAnswerReturns``). Thus a close that ends
    /// the feed with no wait for the answer ends it before the answer
    /// returns, and the feed has no end of the question.
    ///
    /// - Parameters:
    ///   - asked: The question. Its feed is read to the end.
    ///   - answer: The answer on its way, held before the run plane.
    /// - Returns: The rest of the feed, and what the run plane did with the
    ///   answer.
    /// - Throws: When the session is not a ``RoutedSessionActor``, or its
    ///   signal does not report its waiters.
    private static func closeWhileAnEarlierEndWaits(
        for answer: AnswerOnItsWay, of asked: inout AskedQuestion
    ) async throws -> (outputs: [SessionOutput], delivery: ElicitationAnswerDelivery) {
        let session = try asked.fixture.sessionActor()
        let returns = session.questionAnswerReturns
        let waiters = try #require(returns.waiterChanges)
        let gate = answer.gate
        let opener = Task {
            try await waiters.wait(until: { returns.waiterCount >= Self.closeAndTheOwnerOfTheEndWait })
            await gate.open()
        }
        let close = Task { await session.close() }
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)
        // A close that ended the feed with no wait for the answer leaves the
        // gate shut. Open it here, so the answer and the close end.
        opener.cancel()
        await gate.open()
        let delivery = await answer.task.value
        await close.value
        return (outputs, delivery)
    }

    /// Reads the feed through the next ``SessionEvent/runSettled(_:)``, waits
    /// for the terminal event of its run mail, closes the session, and reads
    /// the rest of the feed.
    ///
    /// - Parameter asked: The question. Its feed is read to the end.
    /// - Returns: Each output read, in order.
    /// - Throws: When the feed ends before a `runSettled` with a run mail, or
    ///   what the wait for the terminal event throws.
    private static func outputsThroughTheAnswerOfTheRunMail(of asked: inout AskedQuestion) async throws
        -> [SessionOutput]
    {
        let settled = await SessionWorkEventTests.outputs(
            from: &asked.feed, through: { SessionEventCase.runSettled.matches($0) })
        let last = try #require(settled.last)
        #expect(SessionEventCase.runSettled.matches(last.event))
        for id in try #require(mailIds(of: last.origin)) {
            _ = try await asked.fixture.session.awaitTerminal(of: id)
        }
        await asked.fixture.session.close()
        return settled + (await SessionWorkEventTests.remainingOutputs(of: &asked.feed))
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
        #expect(end.position < (try Self.answeredPosition(ofMailOf: end.origin, in: outputs)))
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a journal that sends
    /// the `runSettled` of the run before the answer on its way returns, so
    /// the end of the question comes after it.
    @Test("a cancel of the run while an answer is on its way gives the end when that answer returns, before the runSettled and the answer of the run mail")
    func aRunCancelWithAnAnswerOnItsWayGivesTheEndBeforeTheTerminal() async throws {
        var asked = try await Self.askQuestion()
        let session = try asked.fixture.sessionActor()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .beforeTheRunPlane)

        let token = asked.question.correlationID
        let cancel = Task { await session.runPlane.cancel(completionToken: token) }
        try await Self.awaitDeferredEnd(of: asked)
        await answer.gate.open()
        let delivery = await answer.task.value
        _ = await cancel.value
        try await Self.expectNoPendingQuestion(asked)
        let outputs = try await Self.outputsThroughTheAnswerOfTheRunMail(of: &asked)

        #expect(delivery == .noPendingElicitation)
        let end = try Self.soleEnd(in: outputs, of: asked)
        let settled = try position(ofFirst: .runSettled, in: outputs)
        #expect(outputs[settled].origin == end.origin)
        #expect(end.position < settled)
        #expect(end.position < (try Self.answeredPosition(ofMailOf: end.origin, in: outputs)))
        await asked.end()
    }

    /// The production change that makes this test fail: an end check that
    /// sends the end of a question whose answer on its way resumed the run.
    @Test("an answer on its way that resumed the run gives no end")
    func anAnswerOnItsWayThatResumedTheRunGivesNoEnd() async throws {
        var asked = try await Self.askQuestion()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .afterTheRunPlane)

        try await Self.awaitDeferredEnd(of: asked)
        await answer.gate.open()
        let delivery = await answer.task.value
        let outputs = try await Self.outputsThroughTheAnswerOfTheRunMail(of: &asked)

        #expect(delivery == .delivered)
        #expect(Self.ends(in: outputs).isEmpty)
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

    /// The production change that makes this test fail: a `cancelAll()`
    /// whose `signalDone` does not wait for the answer on its way, so the
    /// end of the question comes after it.
    @Test("cancelAll() while an answer is on its way gives the end when that answer returns, before the signalDone")
    func cancelAllWithAnAnswerOnItsWayGivesTheEndBeforeItsSignalDone() async throws {
        var asked = try await Self.askQuestion()
        let session = try asked.fixture.sessionActor()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .beforeTheRunPlane)

        let signal = asked.fixture.session.cancelAll()
        try await Self.awaitDeferredEnd(of: asked)
        // The body of the run ends only after the sweep took the question
        // from the run plane. Thus the answer then finds no question.
        await session.runPlane.joinRunBodies()
        await answer.gate.open()
        let delivery = await answer.task.value
        _ = try await asked.fixture.session.awaitTerminal(of: signal)
        try await Self.expectNoPendingQuestion(asked)
        await asked.fixture.session.close()
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        #expect(delivery == .noPendingElicitation)
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
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a `close()` that
    /// ends the feeds before the answer on its way returns, so nobody gets
    /// the end of the question.
    @Test("close() while an answer is on its way gives exactly one end before the feed ends")
    func closeWithAnAnswerOnItsWayGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestion()
        let session = try asked.fixture.sessionActor()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .beforeTheRunPlane)

        let close = Task { await session.close() }
        try await Self.awaitDeferredEnd(of: asked)
        // The body of the run ends only after the sweep took the question
        // from the run plane. Thus the answer then finds no question.
        await session.runPlane.joinRunBodies()
        await answer.gate.open()
        let delivery = await answer.task.value
        await close.value
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &asked.feed)

        #expect(delivery == .noPendingElicitation)
        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(end.origin == .system)
        try await Self.expectNoPendingQuestion(asked)
        await asked.end()
    }

    /// The production change that makes this test fail: a `close()` that
    /// waits only for the answers to the questions whose end its own end
    /// check held, so it ends the feed before the answer to a question whose
    /// end a cancel of the run held.
    @Test("close() while a cancel of the run holds the end for an answer on its way gives exactly one end before the feed ends")
    func closeWhileARunCancelHoldsTheEndGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestion()
        let session = try asked.fixture.sessionActor()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .beforeTheRunPlane)
        let token = asked.question.correlationID
        let cancel = Task { await session.runPlane.cancel(completionToken: token) }
        try await Self.awaitDeferredEnd(of: asked)

        let (outputs, delivery) = try await Self.closeWhileAnEarlierEndWaits(for: answer, of: &asked)
        _ = await cancel.value

        #expect(delivery == .noPendingElicitation)
        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(Self.mailIds(of: end.origin) != nil, "the origin \(end.origin) is not the run mail")
        await asked.end()
    }

    /// The production change that makes this test fail: a `close()` that
    /// waits only for the answers to the questions whose end its own end
    /// check held, so it ends the feed before the answer to a question whose
    /// end a `cancelAll()` signal held.
    @Test("close() while a cancelAll() signal holds the end for an answer on its way gives exactly one end before the feed ends")
    func closeWhileACancelAllHoldsTheEndGivesTheEndBeforeTheFeedEnds() async throws {
        var asked = try await Self.askQuestion()
        let session = try asked.fixture.sessionActor()
        let answer = try await Self.startAnswer(to: asked, holdingAt: .beforeTheRunPlane)
        let signal = asked.fixture.session.cancelAll()
        try await Self.awaitDeferredEnd(of: asked)
        // The body of the run ends only after the sweep took the question
        // from the run plane. Thus the answer then finds no question.
        await session.runPlane.joinRunBodies()

        let (outputs, delivery) = try await Self.closeWhileAnEarlierEndWaits(for: answer, of: &asked)

        #expect(delivery == .noPendingElicitation)
        let end = try Self.soleEnd(in: outputs, of: asked)
        #expect(end.origin == .signal(signal))
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
        questions.noteAsked(request, runToken: runToken, mailID: nil)
        return (questions, request.elicitationId)
    }

    /// The delivery of the ends of close.
    private static let closeDelivery = QuestionEndDelivery.session(.system)

    @Test("a question that left the run plane ends one time, and only for its own run")
    func aQuestionThatLeftEndsOneTime() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let otherRun = questions.endQuestions(ofRun: Self.otherRunToken, notIn: [], completing: [], via: Self.closeDelivery)
        let stillOpen = questions.endQuestions(ofRun: Self.runToken, notIn: [id], completing: [], via: Self.closeDelivery)
        let left = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)
        let lateAnswer = questions.beginAnswer(to: id)

        #expect(otherRun == QuestionEndCheck())
        #expect(stillOpen == QuestionEndCheck())
        #expect(left == QuestionEndCheck(ended: [id]))
        #expect(again == QuestionEndCheck())
        #expect(lateAnswer == false)
    }

    @Test("a question with an answer on its way ends at that answer when the run plane had no question for it")
    func anAnswerOnItsWayDefersTheEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record
        let delivery = QuestionEndDelivery.session(.signal(SignalID()))

        let answerBegan = questions.beginAnswer(to: id)
        let deferred = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: delivery)
        let waitsBefore = questions.hasAnswerOnItsWay(toAnyOf: [id])
        let endDelivery = questions.noteAnswered(id, outcome: .noQuestion)
        let waitsAfter = questions.hasAnswerOnItsWay(toAnyOf: [id])
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)

        #expect(answerBegan)
        #expect(deferred == QuestionEndCheck(deferred: [id]))
        #expect(waitsBefore)
        #expect(endDelivery == delivery)
        #expect(waitsAfter == false)
        #expect(again == QuestionEndCheck())
    }

    /// The production change that makes this test fail: a deferred end that
    /// a later end check takes again, so it gets a second owner or a second
    /// delivery.
    @Test("the first end check owns a deferred end: a later check and a later answer do not touch it")
    func theFirstEndCheckOwnsADeferredEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record
        let delivery = QuestionEndDelivery.session(.signal(SignalID()))

        _ = questions.beginAnswer(to: id)
        _ = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: delivery)
        let laterCheck = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)
        let laterAnswer = questions.beginAnswer(to: id)
        let endDelivery = questions.noteAnswered(id, outcome: .noQuestion)

        #expect(laterCheck == QuestionEndCheck())
        #expect(questions.hasOpenQuestions(ofRun: Self.runToken) == false)
        #expect(laterAnswer == false)
        #expect(endDelivery == delivery)
    }

    /// The production change that makes this test fail: a record that
    /// reports only the ends that the check of close held, so close does not
    /// wait for an end that a cancel-all signal held.
    @Test("the record reports a held end of any end check until the answer returns")
    func theRecordReportsAHeldEndOfAnyCheck() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record
        let signalDelivery = QuestionEndDelivery.session(.signal(SignalID()))

        let before = questions.hasDeferredEnds
        _ = questions.beginAnswer(to: id)
        _ = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: signalDelivery)
        let held = questions.hasDeferredEnds
        _ = questions.noteAnswered(id, outcome: .noQuestion)
        let after = questions.hasDeferredEnds

        #expect(before == false)
        #expect(held)
        #expect(after == false)
    }

    @Test("a question with an answer on its way gives no end when that answer resumed the run")
    func anAnswerThatResumedTheRunGivesNoEnd() {
        let (record, id) = Self.recordWithOneQuestion()
        var questions = record

        let answerBegan = questions.beginAnswer(to: id)
        let deferred = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)
        let endDelivery = questions.noteAnswered(id, outcome: .resumedRun)
        let waitsAfter = questions.hasAnswerOnItsWay(toAnyOf: [id])
        let again = questions.endQuestions(ofRun: Self.runToken, notIn: [], completing: [], via: Self.closeDelivery)

        #expect(answerBegan)
        #expect(deferred == QuestionEndCheck(deferred: [id]))
        #expect(endDelivery == nil)
        #expect(waitsAfter == false)
        #expect(again == QuestionEndCheck())
    }

    /// A record with one URL-mode question of ``runToken``.
    ///
    /// - Returns: The record and the id of the question.
    private static func recordWithOneURLQuestion() -> (questions: AskedQuestions, id: ULID) {
        var questions = AskedQuestions()
        let id = ULID.generate()
        let request = ElicitationRequest(message: "Open the page", elicitationId: id, url: SessionWorkEventTests.approvalURL)
        questions.noteAsked(request, runToken: runToken, mailID: nil)
        return (questions, id)
    }

    /// The production change that makes this test fail: an end check that
    /// ends a question whose completion post is on its way, or a record that
    /// does not report that post, so a stop of the session does not wait
    /// for it.
    @Test("a question whose completion post is on its way gets no end, and the record reports it until the post")
    func aCompletingQuestionGetsNoEnd() {
        let (record, id) = Self.recordWithOneURLQuestion()
        var questions = record

        let check = questions.endQuestions(ofRun: nil, notIn: [], completing: [id], via: Self.closeDelivery)
        let onItsWay = questions.hasCompletionOnItsWay(toAnyOf: [id])
        let anyOnItsWay = questions.hasCompletionsOnTheirWay
        let lateAnswer = questions.beginAnswer(to: id)
        let laterCheck = questions.endQuestions(ofRun: nil, notIn: [], completing: [], via: Self.closeDelivery)
        let posted = questions.complete(id, postedBy: .system)

        #expect(check == QuestionEndCheck(completing: [id]))
        #expect(onItsWay)
        #expect(anyOnItsWay)
        #expect(lateAnswer == false)
        #expect(laterCheck == QuestionEndCheck())
        #expect(posted != nil)
        #expect(questions.hasCompletionsOnTheirWay == false)
    }

    /// The production change that makes this test fail: a record that takes
    /// a question out when the completion of the client returns after an end
    /// check marked the question completed, so the post finds no question.
    @Test("a completion of the client that returns after an end check marked the question completed keeps it until the post")
    func aLateCompletionKeepsTheCompletedQuestion() {
        let (record, id) = Self.recordWithOneURLQuestion()
        var questions = record

        _ = questions.beginAnswer(to: id)
        _ = questions.noteAnswered(id, outcome: .acceptedAwaitingCompletion)
        _ = questions.beginAnswer(to: id)
        _ = questions.endQuestions(ofRun: nil, notIn: [], completing: [id], via: Self.closeDelivery)
        let endDelivery = questions.noteAnswered(id, outcome: .resumedRun)

        #expect(endDelivery == nil)
        #expect(questions.hasCompletionOnItsWay(toAnyOf: [id]))
        #expect(questions.complete(id, postedBy: .system) != nil)
    }

    /// The production change that makes this test fail: a record that opens
    /// the question again when an accept returns after an end check marked
    /// the question completed, so a later end check ends it.
    @Test("an accept that returns after an end check marked the question completed does not open it again")
    func aLateAcceptKeepsTheCompletedQuestion() {
        let (record, id) = Self.recordWithOneURLQuestion()
        var questions = record

        _ = questions.beginAnswer(to: id)
        _ = questions.endQuestions(ofRun: nil, notIn: [], completing: [id], via: Self.closeDelivery)
        let endDelivery = questions.noteAnswered(id, outcome: .acceptedAwaitingCompletion)
        let laterCheck = questions.endQuestions(ofRun: nil, notIn: [], completing: [], via: Self.closeDelivery)

        #expect(endDelivery == nil)
        #expect(laterCheck == QuestionEndCheck())
        #expect(questions.hasCompletionOnItsWay(toAnyOf: [id]))
    }
}
