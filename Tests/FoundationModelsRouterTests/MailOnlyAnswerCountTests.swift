import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^cgtxr00: which answers count toward
/// ``SessionConfiguration/mailOnlyAnswerLimit``.
///
/// A mail-only answer counts only when a new background run started in it:
/// a run that is open at the end of the answer, and that was not open at its
/// start. One answer adds one at most. A mail-only answer that started no
/// run keeps the count. User-type mail sets the count to zero
/// (`MailOnlyAnswerLimitTests`).
///
/// Each test runs in a fixed order: it settles each run and sends each
/// message one at a time, and it waits until the pump handled each one
/// (``MailOnlyAnswerFixtures``). The suite needs no network and no GPU.
@Suite("The answers that count toward the bound on mail-only answers")
struct MailOnlyAnswerCountTests {
    /// The fixtures of the suite.
    typealias Fixtures = MailOnlyAnswerFixtures

    // MARK: - Constants

    /// The limit each test session has: small, so a test runs few submissions.
    private static let limit = 3

    /// The prompt of the first caller message. Its answer attaches the outbox
    /// of the session, so later mail wakes the pump.
    private static let firstPrompt = "start the work"

    /// The name of the background tool of each session.
    private static let jobName = "build_job"

    /// The count of messages that one background run sends, far past
    /// ``limit``.
    private static let messageCount = 10

    /// The count of mail-only answers in the test of runs that settle inside
    /// their settle period, past ``limit``.
    private static let inlineAnswerCount = 5

    /// The settle period of the tool whose runs settle inside it. The run
    /// clock of each session is manual and does not move, so the period
    /// never ends, and each run settles inside it when its gate is open.
    private static let neverEndingSettlePeriod: TimeInterval = 1

    /// The prompts of the caller answer and of the answer of the terminal of
    /// the messaging run, beside the answers of the messages.
    private static let callerAndTerminalPrompts = 2

    /// The answers that start a run, up to the limit, beside the caller
    /// answer.
    private static let promptsOfOneChain = limit + 1

    /// The messaging run, beside the runs of the tool, in the settled runs of
    /// a session.
    private static let messagingRuns = 1

    // MARK: - Fixtures

    /// Makes a session with ``limit`` and the one fixture tool `tool`, whose
    /// backend calls `tool` in each call that `callsTool` names.
    ///
    /// - Parameters:
    ///   - tool: The fixture tool of the session.
    ///   - gates: The gates of the runs of `tool`.
    ///   - callsTool: Whether the backend call with a one-based ordinal calls
    ///     `tool`.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        tool: any Tool, gates: Fixtures.RunGates, callsTool: @escaping @Sendable (Int) -> Bool
    ) async throws -> Fixtures.Session {
        try await Fixtures.Session.make(
            prefix: "MailOnlyAnswerCountTests", limit: limit, tool: tool, gates: gates, callsTool: callsTool)
    }

    /// Sends the first caller message, and waits until the pump ended its
    /// answer.
    ///
    /// - Parameter fixture: The fixture of the session.
    /// - Throws: What the answer throws.
    private static func answerTheFirstPrompt(on fixture: Fixtures.Session) async throws {
        _ = try await fixture.session.respond(to: firstPrompt)
        #expect(await fixture.session.pumpEnds())
    }

    /// The text of the message with a one-based ordinal.
    ///
    /// - Parameter ordinal: The ordinal of the message.
    /// - Returns: The text.
    private static func message(_ ordinal: Int) -> String {
        "step \(ordinal) of the build is done"
    }

    /// Sends `count` messages from `run`, one at a time.
    ///
    /// - Parameters:
    ///   - count: How many messages to send.
    ///   - run: The run that sends them.
    private static func sendMessages(_ count: Int, from run: Fixtures.MessagingRun) async {
        for ordinal in 1...count {
            await run.send(message(ordinal))
        }
    }

    // MARK: - Answers that start no run

    /// The production change that makes this test fail: a count that adds
    /// one for each mail-only answer, also for an answer that started no
    /// run. The fourth message then pauses the delivery.
    @Test("many messages of one background run start many mail-only answers that start no run, and none pauses")
    func manyMessagesOfOneRunDoNotPause() async throws {
        let gates = Fixtures.RunGates()
        let fixture = try await Self.makeFixture(
            tool: Fixtures.GatedJob(name: Self.jobName, gates: gates), gates: gates, callsTool: { _ in false })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        try await Self.answerTheFirstPrompt(on: fixture)

        await Self.sendMessages(Self.messageCount, from: messaging)
        try await messaging.settle()

        #expect(fixture.backend.prompts.count == Self.messageCount + Self.callerAndTerminalPrompts)
        #expect(await fixture.waitingMail().isEmpty)
        #expect(await fixture.end().mailDeliveryPauses.isEmpty)
    }

    /// The production change that makes this test fail: a count that adds
    /// one for a mail-only answer whose run started and settled inside the
    /// answer. The fourth message then pauses the delivery.
    @Test("a run that settles inside its settle period does not count, so its mail-only answers do not pause")
    func aRunThatSettlesInsideTheAnswerDoesNotCount() async throws {
        let gates = Fixtures.RunGates(opensEachGate: true)
        let job = Fixtures.GatedJob(name: Self.jobName, gates: gates, settlePeriod: Self.neverEndingSettlePeriod)
        let fixture = try await Self.makeFixture(tool: job, gates: gates, callsTool: { _ in true })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        try await Self.answerTheFirstPrompt(on: fixture)

        await Self.sendMessages(Self.inlineAnswerCount, from: messaging)
        try await messaging.settle()

        let answers = Self.inlineAnswerCount + Self.callerAndTerminalPrompts
        #expect(fixture.backend.prompts.count == answers)
        // Each answer started one run of the tool, and each run settled in
        // its own call.
        #expect(await fixture.session.runPlane.backgroundRuns().isEmpty)
        #expect(await fixture.session.runPlane.settledRunTokens().count == answers + Self.messagingRuns)
        #expect(await fixture.end().mailDeliveryPauses.isEmpty)
    }

    // MARK: - Answers that start a run

    /// The production change that makes this test fail: a count that starts
    /// again at zero after a mail-only answer that started no run. The
    /// count then never reaches the limit.
    @Test("answers that start a run, mixed with message answers that start none, pause after the limit of run starts")
    func messageAnswersKeepTheCount() async throws {
        // Calls 2, 4 and 6 start a run: the answers of the first message and
        // of the terminals of the first two runs.
        let runStartingCalls: Set = [2, 4, 6]
        let gates = Fixtures.RunGates()
        let fixture = try await Self.makeFixture(
            tool: Fixtures.GatedJob(name: Self.jobName, gates: gates), gates: gates,
            callsTool: { runStartingCalls.contains($0) })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        try await Self.answerTheFirstPrompt(on: fixture)

        await messaging.send(Self.message(1))
        await messaging.send(Self.message(2))
        try await fixture.settleTheOpenRun(of: Self.jobName)
        await messaging.send(Self.message(3))
        try await fixture.settleTheOpenRun(of: Self.jobName)
        let pausingMessage = Self.message(4)
        await messaging.send(pausingMessage)

        try await fixture.waitForPauses(1)
        // The caller answer, the answers of three messages, and the answers
        // of the terminals of two runs.
        let deliveredMessages = 3
        let deliveredTerminals = 2
        #expect(fixture.backend.prompts.count == 1 + deliveredMessages + deliveredTerminals)
        let held = await fixture.waitingMail()
        #expect(held.allSatisfy { $0.isHeld })
        #expect(held.contains { $0.event.kind == .message && $0.event.detail == pausingMessage })
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }

    /// The production change that makes this test fail: a count that sees
    /// only the runs that the model started with its own tool call, and not
    /// the inner run that a tool body leaves open on its context.
    @Test("a tool body that leaves an inner background run open counts, so a chain of such answers pauses")
    func anInnerRunOfAToolBodyCounts() async throws {
        let gates = Fixtures.RunGates()
        let starter = Fixtures.InnerJobStarter(job: Fixtures.GatedJob(name: Self.jobName, gates: gates))
        let fixture = try await Self.makeFixture(tool: starter, gates: gates, callsTool: { _ in true })
        try await Self.answerTheFirstPrompt(on: fixture)

        // The run of the caller answer, then the run of each of the `limit`
        // answers that mail alone started. The bound holds the terminal of
        // the last run.
        try await fixture.settleTheOpenRuns(Self.promptsOfOneChain, of: Self.jobName)

        try await fixture.waitForPauses(1)
        #expect(fixture.backend.prompts.count == Self.promptsOfOneChain)
        let held = await fixture.waitingMail()
        #expect(held.allSatisfy { $0.isHeld })
        #expect(held.contains { $0.event.kind == .completed && $0.event.detail.contains(Fixtures.GatedJob.output) })
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }
}
