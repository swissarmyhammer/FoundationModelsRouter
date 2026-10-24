import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^9bxas0w: the safety bound on a chain of answers that mail
/// alone starts.
///
/// Mail causes the next submission of a session with no caller call. A model
/// that starts one more background run in each submission thus gets one more
/// delivery for each run, with no end. The pump counts the mail-only answers
/// that started a new background run (task ^cgtxr00). At
/// ``SessionConfiguration/mailOnlyAnswerLimit`` it holds the mail in the
/// outbox for the next caller message, and it sends
/// ``SessionEvent/mailDeliveryPaused(_:)``.
///
/// Everything runs against a scripted backend that calls a real background
/// tool of the session (``MailOnlyAnswerFixtures``), so the suite needs no
/// network and no GPU. Each run of that tool waits at its own gate, so it is
/// still open when the answer that started it ends. The test then settles it,
/// and its terminal starts the next answer.
@Suite("The bound on a chain of answers that mail alone starts")
struct MailOnlyAnswerLimitTests {
    /// The fixtures of the suite.
    typealias Fixtures = MailOnlyAnswerFixtures

    // MARK: - Constants

    /// The prefix of the temporary directory of the router of each session.
    private static let directoryPrefix = "MailOnlyAnswerLimitTests"

    /// The prompt of the first caller message, which starts the chain.
    private static let firstPrompt = "start the status checks"

    /// The prompt of the caller message after the chain stopped.
    private static let nextPrompt = "what is the status now"

    /// Whether the backend call with a one-based ordinal starts a run: each
    /// call does.
    private static let everyCall: @Sendable (Int) -> Bool = { _ in true }

    // MARK: - The bound

    @Test("an endless chain of mail-only answers stops at the limit, and the session sends the pause event")
    func anEndlessChainStopsAtTheLimit() async throws {
        let fixture = try await Fixtures.Session.make(prefix: Self.directoryPrefix, callsTool: Self.everyCall)
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

        // The caller answer, then `limit` answers that mail alone started.
        // Each of them started a run that was still open when it ended.
        try await fixture.settleTheRunsOfOneChain()

        try await fixture.waitForPauses(1)
        #expect(fixture.backend.prompts.count == Fixtures.promptsOfOneChain)
        // The mail of the last run waits, held: its progress report and its
        // terminal.
        let held = await fixture.waitingMail()
        #expect(held.filter { $0.event.kind == .completed }.count == 1)
        #expect(held.allSatisfy { $0.isHeld })
        let pause = try #require(await fixture.events.events.mailDeliveryPauses.first)
        #expect(pause == MailDeliveryPause(limit: Fixtures.limit, heldMail: held.map(\.event)))
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }

    @Test("the mail that the bound holds rides the next caller message")
    func theHeldMailRidesTheNextCallerMessage() async throws {
        // The last run starts in the last answer that mail started, so the
        // bound holds its mail, and the next caller answer starts no run.
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix, callsTool: { $0 <= Fixtures.promptsOfOneChain })
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)
        try await fixture.settleTheRunsOfOneChain()
        try await fixture.waitForPauses(1)
        let held = try #require(await fixture.waitingMail().first { $0.event.kind == .completed })

        _ = try await fixture.session.respond(to: Self.nextPrompt)

        let nextCallerPrompt = try #require(fixture.backend.prompts.dropFirst(Fixtures.promptsOfOneChain).first)
        #expect(nextCallerPrompt.contains(OperationEventSegment.renderedLine(for: held.event)))
        #expect(nextCallerPrompt.hasSuffix(Self.nextPrompt))
        #expect(await fixture.waitingMail().isEmpty)
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }

    @Test("a caller message starts the count again, so mail again starts answers up to the limit")
    func aCallerMessageStartsTheCountAgain() async throws {
        let fixture = try await Fixtures.Session.make(prefix: Self.directoryPrefix, callsTool: Self.everyCall)
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)
        try await fixture.settleTheRunsOfOneChain()
        try await fixture.waitForPauses(1)

        // The caller message carries the held mail, and its answer starts one
        // more run. User-type mail sets the count to zero.
        try await fixture.answerCallerPrompt(Self.nextPrompt)
        try await fixture.settleTheRunsOfOneChain()

        // The second chain pauses too: one pause for each chain.
        let pausesOfTwoChains = 2
        try await fixture.waitForPauses(pausesOfTwoChains)
        #expect(fixture.backend.prompts.count == Fixtures.promptsOfOneChain + Fixtures.promptsOfOneChain)
        #expect(await fixture.end().mailDeliveryPauses.count == pausesOfTwoChains)
    }

    @Test("a chain of `limit` mail-only answers whose last answer starts no run runs whole with no pause")
    func aChainUpToTheLimitRunsWhole() async throws {
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix, callsTool: { $0 <= Fixtures.limit })
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

        // Each of the first `limit` calls started a run, and the mail of each
        // run started one more answer. The last answer started no run.
        try await fixture.settleTheOpenRuns(Fixtures.limit)

        #expect(fixture.backend.prompts.count == Fixtures.promptsOfOneChain)
        #expect(await fixture.waitingMail().isEmpty)
        // Only the pump sends a pause, and the pump ended. The close then
        // finishes the feed after each event that the pump sent, so a pause
        // is in the events now, or never came.
        #expect(await fixture.end().mailDeliveryPauses.isEmpty)
        #expect(fixture.backend.prompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })
    }

    @Test("a limit of zero holds all mail for the next caller message")
    func aLimitOfZeroHoldsAllMail() async throws {
        let fixture = try await Fixtures.Session.make(
            prefix: Self.directoryPrefix, limit: 0, callsTool: Self.everyCall)
        defer { await fixture.end() }
        try await fixture.answerCallerPrompt(Self.firstPrompt)

        try await fixture.settleTheOpenRun()

        try await fixture.waitForPauses(1)
        #expect(fixture.backend.prompts == [Self.firstPrompt])
        let held = await fixture.waitingMail()
        #expect(!held.isEmpty)
        #expect(held.allSatisfy { $0.isHeld })
        #expect(await fixture.end().mailDeliveryPauses.count == 1)
    }

    // MARK: - The setting

    @Test("a session configuration that names no limit carries the named default")
    func theConfigurationCarriesTheDefault() {
        #expect(SessionConfiguration().mailOnlyAnswerLimit == SessionConfiguration.defaultMailOnlyAnswerLimit)
    }

    /// The configuration slice that a session's `index.md` holds keeps the
    /// limit through an encode and a decode.
    @Test("the record form of a configuration keeps the limit")
    func thePersistableFormKeepsTheLimit() throws {
        let persistable = SessionConfiguration(mailOnlyAnswerLimit: Fixtures.limit).persistable
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONEncoder().encode(persistable))
        #expect(decoded.mailOnlyAnswerLimit == Fixtures.limit)
    }
}

extension Sequence<SessionEvent> {
    /// The mail delivery pauses among these events, in order.
    var mailDeliveryPauses: [MailDeliveryPause] {
        compactMap { event in
            guard case .mailDeliveryPaused(let pause) = event else { return nil }
            return pause
        }
    }
}
