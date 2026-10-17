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

    /// The prefix of the temporary directory of the router of each session.
    private static let directoryPrefix = "MailOnlyAnswerCountTests"

    /// The prompt of the first caller message. Its answer attaches the outbox
    /// of the session, so later mail wakes the pump.
    private static let firstPrompt = "start the work"

    /// The count of messages that one background run sends, far past
    /// ``MailOnlyAnswerFixtures/limit``.
    private static let messageCount = 10

    /// The count of mail-only answers in the test of runs that settle inside
    /// their settle period, past ``MailOnlyAnswerFixtures/limit``.
    private static let inlineAnswerCount = 5

    /// The settle period of the tool whose runs settle inside it. The run
    /// clock of each session is manual and does not move, so the period
    /// never ends, and each run settles inside it when its gate is open.
    private static let neverEndingSettlePeriod: TimeInterval = 1

    /// The prompts of the caller answer and of the answer of the terminal of
    /// the messaging run, beside the answers of the messages.
    private static let callerAndTerminalPrompts = 2

    /// The messaging run, beside the runs of the tool, in the settled runs of
    /// a session.
    private static let messagingRuns = 1

    // MARK: - Fixtures

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
        let fixture = try await Fixtures.Session.make(prefix: Self.directoryPrefix, callsTool: { _ in false })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        defer {
            await messaging.gate.open()
            await fixture.end()
        }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

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
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix, gates: Fixtures.RunGates(opensEachGate: true),
            tool: { Fixtures.GatedJob(name: Fixtures.jobName, gates: $0, settlePeriod: Self.neverEndingSettlePeriod) },
            callsTool: { _ in true })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        defer {
            await messaging.gate.open()
            await fixture.end()
        }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

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
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix, callsTool: { runStartingCalls.contains($0) })
        let messaging = await Fixtures.MessagingRun.start(on: fixture.session)
        defer {
            await messaging.gate.open()
            await fixture.end()
        }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

        await messaging.send(Self.message(1))
        await messaging.send(Self.message(2))
        try await fixture.settleTheOpenRun()
        await messaging.send(Self.message(3))
        try await fixture.settleTheOpenRun()
        let pausingMessage = Self.message(4)
        await messaging.send(pausingMessage)

        // The caller answer, the answers of three messages, and the answers
        // of the terminals of two runs. The send waited until the pump
        // handled the fourth message, so the count is final here. A count
        // that does not pause delivers the fourth message, and the test fails
        // here, before it waits for a pause that never comes (rule T1).
        let deliveredMessages = 3
        let deliveredTerminals = 2
        try #require(fixture.backend.prompts.count == 1 + deliveredMessages + deliveredTerminals)
        try await fixture.waitForPauses(1)
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
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix,
            tool: { Fixtures.InnerJobStarter(job: Fixtures.GatedJob(name: Fixtures.jobName, gates: $0)) },
            callsTool: { _ in true })
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

        // The run of the caller answer, then the run of each of the `limit`
        // answers that mail alone started. The bound holds the terminal of
        // the last run.
        try await fixture.settleTheRunsOfOneChain()

        // The settle waited until the pump handled the last terminal, so the
        // count is final here. A count that misses the inner run delivers
        // that terminal, and the test fails here, before it waits for a pause
        // that never comes (rule T1).
        try #require(fixture.backend.prompts.count == Fixtures.promptsOfOneChain)
        try await fixture.waitForPauses(1)
        let held = await fixture.waitingMail()
        #expect(held.allSatisfy { $0.isHeld })
        #expect(held.contains { $0.event.kind == .completed && $0.event.detail.contains(Fixtures.GatedJob.output) })
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }
}
