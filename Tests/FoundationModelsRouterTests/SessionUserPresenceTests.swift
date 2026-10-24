import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^0hps8jg: ``SessionConfiguration/userPresence`` sets the
/// user presence of the run plane of a session.
///
/// In a headless session, the question of a tool ends at once with a cancel
/// that gives `RunPlane.noUserPresentReason`. The session sends no
/// ``SessionEvent/elicitationRequested(_:)`` and no
/// ``SessionEvent/elicitationEnded(_:)``, and it sends
/// ``SessionEvent/workEnded`` as usual. A session with no setting stays
/// interactive.
///
/// Everything runs against the scripted ``BackgroundingBackend`` and real
/// background tools of the session, so the suite needs no network and no
/// GPU. A gate holds each run until the test has run one check of the work
/// end after the end of the pump
/// (``SessionWorkEventTests/checkWorkEndAfterThePump(of:)``), so the order of
/// the outputs is the same in each run of the test. The tests read that
/// order, not a clock.
@Suite("The user presence of a session sets how the questions of its tools end")
struct SessionUserPresenceTests {
    // MARK: - Fixtures

    /// The answers that the question of a ``RecordingAskingTool`` got, in
    /// order.
    final class AnswerLog: Sendable {
        /// The answers, in order.
        private let stored = Mutex<[ElicitationResponse]>([])

        /// The answers, in order.
        var answers: [ElicitationResponse] { stored.withLock { $0 } }

        /// Records one answer.
        ///
        /// - Parameter answer: The answer that the question got.
        func record(_ answer: ElicitationResponse) {
            stored.withLock { $0.append(answer) }
        }
    }

    /// A background tool whose run asks the user one question through
    /// `ToolContext.elicit(_:)`, records the answer in ``answers``, and
    /// returns. The run asks its question only after ``askGate`` opens.
    struct RecordingAskingTool: Tool, BackgroundTool {
        let name = "recording_asking_job"
        let description = "test-only background tool whose run asks the user one question and records the answer"

        /// The gate that the run waits on before it asks its question.
        let askGate: RunLatch

        /// The log of the answers of the question.
        let answers: AnswerLog

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { return SessionWorkEventTests.noContextOutput }
            await askGate.waitUntilOpen()
            answers.record(try await context.elicit(MountFixtures.proceedRequest()))
            return SessionUserPresenceTests.runOutput
        }
    }

    // MARK: - Constants

    /// The output of a ``RecordingAskingTool`` run.
    static let runOutput = "the question ended"

    /// The prompt of each caller message.
    private static let jobPrompt = "run the job"

    /// The prefix of the temporary directory of each fixture.
    private static let prefix = "SessionUserPresenceTests"

    /// The one answer that a headless session gives to each question.
    private static let headlessAnswer = ElicitationResponse.cancel(reason: RunPlane.noUserPresentReason)

    // MARK: - Helpers

    /// Whether `event` tells the host about a question.
    ///
    /// - Parameter event: An event of a session.
    /// - Returns: `true` for ``SessionEvent/elicitationRequested(_:)`` and
    ///   ``SessionEvent/elicitationEnded(_:)``.
    private static func isQuestionEvent(_ event: SessionEvent) -> Bool {
        SessionEventCase.elicitationRequested.matches(event) || SessionEventCase.elicitationEnded.matches(event)
    }

    // MARK: - Tests

    /// The production change that makes this test fail: a session that
    /// makes its run plane with no user presence. The run plane is then
    /// interactive, so the question goes to the host and the run waits.
    @Test("a configured user presence reaches the run plane of the session, and the default is interactive")
    func theConfiguredPresenceReachesTheRunPlane() async throws {
        let headless = try await BackgroundingSessionFixture.make(
            prefix: Self.prefix, tools: [], userPresence: .headless)
        defer { await headless.end() }
        let interactive = try await BackgroundingSessionFixture.make(prefix: Self.prefix, tools: [])
        defer { await interactive.end() }

        #expect(try headless.sessionActor().runPlane.userPresence == .headless)
        #expect(try interactive.sessionActor().runPlane.userPresence == .interactive)
    }

    /// The production change that makes this test fail: a session that
    /// makes its run plane with no user presence. The question then goes to
    /// the host as ``SessionEvent/elicitationRequested(_:)``, and the run
    /// waits for an answer that does not come.
    @Test("in a headless session a question ends at once with a cancel, no question event comes, and the work ends once after the run settles")
    func aHeadlessQuestionEndsAtOnceWithNoQuestionEvent() async throws {
        let askGate = RunLatch()
        let answers = AnswerLog()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: Self.prefix, tools: [RecordingAskingTool(askGate: askGate, answers: answers)],
            userPresence: .headless)
        defer { await fixture.end(opening: [askGate]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        try await SessionWorkEventTests.checkWorkEndAfterThePump(of: fixture.sessionActor())
        await askGate.open()
        let untilWorkEnd = await SessionWorkEventTests.outputs(throughNextWorkEnd: &feed)
        await fixture.session.close()
        let outputs = untilWorkEnd + (await SessionWorkEventTests.remainingOutputs(of: &feed))

        #expect(answers.answers == [Self.headlessAnswer])
        #expect(!outputs.map(\.event).contains(where: Self.isQuestionEvent))
        #expect(SessionWorkEventTests.workEvents(of: outputs) == [.workStarted, .workEnded])
        let settled = try position(ofFirst: .runSettled, in: untilWorkEnd)
        #expect(settled < untilWorkEnd.count - 1)
    }

    /// The production change that makes this test fail: a session that
    /// makes its run plane headless when the configuration gives no user
    /// presence. The question then ends at once, and no question event
    /// comes.
    @Test("a session with no user presence setting sends the question of a tool to the host, as before")
    func aDefaultSessionSendsTheQuestionToTheHost() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: Self.prefix,
            tools: [SessionWorkEventTests.AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        defer { await fixture.end(opening: [askGate, returnGate]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        let asking = try await SessionWorkEventTests.outputsUpToTheQuestion(
            of: fixture, askGate: askGate, feed: &feed)

        let question = try firstQuestion(in: asking)
        #expect(question.kind == .elicitation)
    }
}
