import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^v270zf4: the delivery of a message that a background run
/// sends to its session while the run continues (`ToolContext.message(_:)`,
/// ``OperationEventKind/message``).
///
/// A message of a background run is mail that starts an answer with no
/// caller message, as the terminal of a settled background run does. The run
/// stays open, and its terminal later starts an answer of its own. A message
/// of a run that is no background run starts no answer: it rides the next
/// submission. Every message is also on the session-wide feed as
/// ``SessionEvent/runMessage(_:)``.
///
/// Everything runs against the scripted backend of
/// ``SessionMessagePumpTests``, so the suite needs no network and no GPU.
@Suite("The delivery of a message of a background run")
struct RunMessageDeliveryTests {
    /// The scripted backend of each test.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// One session over a ``Backend``, with what a test reads.
    struct Fixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: Backend

        /// The feed of the session's events.
        let events: SessionEventLog

        /// The task that drains ``events``.
        let drain: Task<Void, Never>

        /// The profile that keeps the models of the session resident.
        let profile: LanguageModelProfile

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The prompt of the first caller message. Its answer attaches the outbox
    /// of the session, so later mail wakes the pump.
    private static let firstPrompt = "start the background job"

    /// The prompt of the caller message after the mail.
    private static let nextPrompt = "what did the job say"

    /// The text of the message that the background run sends.
    private static let messageText = "half of the files are done"

    /// The detail of the terminal of the background run.
    private static let terminalDetail = "all of the files are done"

    /// The ordinal of the first submission of the answer that the message
    /// starts: one caller answer runs before it.
    private static let messageAnswerSubmission = 2

    /// The ordinal of the first submission of the answer that the terminal
    /// starts, after the answer that the message started.
    private static let terminalAnswerSubmission = 3

    // MARK: - Fixtures

    /// Makes a session over a new backend that follows `script`, and watches
    /// its events.
    ///
    /// - Parameters:
    ///   - script: What each call of the backend does, by its one-based
    ///     ordinal.
    ///   - mailOnlyAnswerLimit: The ``SessionConfiguration/mailOnlyAnswerLimit``
    ///     of the session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        script: [Int: SessionMessagePumpTests.ScriptedCall] = [:],
        mailOnlyAnswerLimit: Int = SessionConfiguration.defaultMailOnlyAnswerLimit
    ) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "RunMessageDeliveryTests")
        let backend = Backend(script: script)
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: directory
        ).profile
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(mailOnlyAnswerLimit: mailOnlyAnswerLimit))
        let (events, drain) = await SessionEventLog.watch(session)
        return Fixture(
            session: session, backend: backend, events: events, drain: drain, profile: profile, directory: directory)
    }

    /// Ends the fixture: stops the event drain and removes the directory.
    ///
    /// - Parameter fixture: The fixture to end.
    private static func tearDown(_ fixture: Fixture) {
        fixture.drain.cancel()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.profile) {}
    }

    /// Starts one background run on the mailbox of `session` that stays open
    /// until `latch` opens.
    ///
    /// - Parameters:
    ///   - session: The session whose mailbox tracks the run.
    ///   - latch: The latch that settles the run when it opens.
    /// - Returns: The completion token of the run.
    private static func openRun(on session: any RoutedSession, until latch: RunLatch) async -> String {
        await trackFakeRun(on: session.mailbox, latch: latch, detailOnSettle: terminalDetail)
    }

    /// The message that the run with `token` sends to its session.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The `.message` event.
    private static func message(of token: String) -> OperationEvent {
        OperationEvent(tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .message, detail: messageText)
    }

    /// Whether the run with `token` is open on the mailbox of `session`.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - session: The session whose mailbox tracks the run.
    /// - Returns: `true` when the run is open.
    private static func isOpen(_ token: String, on session: any RoutedSession) async -> Bool {
        await session.mailbox.backgroundRuns().contains { $0.completionToken == token }
    }

    // MARK: - Delivery

    @Test("a message of an open background run starts an answer with no caller message, and the run stays open")
    func aMessageOfAnOpenRunStartsAnAnswer() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let latch = RunLatch()
        let token = await Self.openRun(on: fixture.session, until: latch)
        _ = try await fixture.session.respond(to: Self.firstPrompt)

        await fixture.session.outbox.post(event: Self.message(of: token))

        try await BoundedWait.awaitPrompts(Self.messageAnswerSubmission, in: { fixture.backend.prompts })
        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: Self.message(of: token))))
        #expect(prompt.hasSuffix(RoutedSessionActor.runMessageDeliveryPrompt))
        #expect(await BoundedWait.pumpStops(on: fixture.session))
        #expect(await Self.isOpen(token, on: fixture.session))
        await latch.open()
    }

    @Test("a later terminal of the same run settles the run and starts an answer of its own")
    func aLaterTerminalStartsItsOwnAnswer() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let latch = RunLatch()
        let token = await Self.openRun(on: fixture.session, until: latch)
        _ = try await fixture.session.respond(to: Self.firstPrompt)
        await fixture.session.outbox.post(event: Self.message(of: token))
        try await BoundedWait.awaitPrompts(Self.messageAnswerSubmission, in: { fixture.backend.prompts })
        #expect(await BoundedWait.pumpStops(on: fixture.session))

        await latch.open()
        let terminal = try await MountFixtures.settledTerminal(of: token, in: fixture.session.mailbox)
        await fixture.session.outbox.post(event: terminal)

        try await BoundedWait.awaitPrompts(Self.terminalAnswerSubmission, in: { fixture.backend.prompts })
        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: terminal)))
        #expect(prompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(await Self.isOpen(token, on: fixture.session) == false)
    }

    @Test("a message that arrives while an answer runs waits, and the next answer carries it")
    func aMessageWhileAnAnswerRunsWaitsForTheNextAnswer() async throws {
        let holdFirstAnswer = RunLatch()
        let fixture = try await Self.makeFixture(script: [1: .hold(holdFirstAnswer)])
        defer { Self.tearDown(fixture) }
        let latch = RunLatch()
        let token = await Self.openRun(on: fixture.session, until: latch)
        let firstAnswer = Task { try await fixture.session.respond(to: Self.firstPrompt) }
        try await BoundedWait.awaitPrompts(1, in: { fixture.backend.prompts })

        await fixture.session.outbox.post(event: Self.message(of: token))

        #expect(fixture.backend.prompts.count == 1)
        #expect(await fixture.session.outbox.pending().events.map(\.event) == [Self.message(of: token)])
        await holdFirstAnswer.open()
        _ = try await firstAnswer.value
        try await BoundedWait.awaitPrompts(Self.messageAnswerSubmission, in: { fixture.backend.prompts })
        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: Self.message(of: token))))
        #expect(prompt.hasSuffix(RoutedSessionActor.runMessageDeliveryPrompt))
        await latch.open()
    }

    @Test("a message of a run that is no background run starts no answer, and rides the next caller message")
    func aMessageOfAnUnknownRunRidesTheNextCallerMessage() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        _ = try await fixture.session.respond(to: Self.firstPrompt)
        let inBandMessage = Self.message(of: "in-band-run")

        await fixture.session.outbox.post(event: inBandMessage)

        #expect(await BoundedWait.pumpStops(on: fixture.session))
        #expect(fixture.backend.prompts == [Self.firstPrompt])
        _ = try await fixture.session.respond(to: Self.nextPrompt)
        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: inBandMessage)))
        #expect(prompt.hasSuffix(Self.nextPrompt))
        #expect(await fixture.session.outbox.pending().events.isEmpty)
    }

    @Test("the bound on answers that mail alone starts holds a message, and the session sends the pause event")
    func theMailOnlyAnswerLimitHoldsAMessage() async throws {
        let fixture = try await Self.makeFixture(mailOnlyAnswerLimit: 0)
        defer { Self.tearDown(fixture) }
        let latch = RunLatch()
        let token = await Self.openRun(on: fixture.session, until: latch)
        _ = try await fixture.session.respond(to: Self.firstPrompt)

        await fixture.session.outbox.post(event: Self.message(of: token))

        #expect(
            await BoundedWait.conditionReached("one mail delivery pause on the session feed") {
                await fixture.events.mailDeliveryPauses.count == 1
            })
        #expect(await BoundedWait.pumpStops(on: fixture.session))
        #expect(fixture.backend.prompts == [Self.firstPrompt])
        let held = await fixture.session.outbox.pending().events
        #expect(held.map(\.event) == [Self.message(of: token)])
        #expect(held.allSatisfy { $0.isHeld })
        await latch.open()
    }

    @Test("a message of a background run arrives on streamSessionEvents() as runMessage")
    func aMessageArrivesOnTheSessionFeed() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let latch = RunLatch()
        let token = await Self.openRun(on: fixture.session, until: latch)
        _ = try await fixture.session.respond(to: Self.firstPrompt)

        await fixture.session.outbox.post(event: Self.message(of: token))

        #expect(
            await BoundedWait.conditionReached("runMessage on the session feed") {
                await fixture.events.runMessages == [Self.message(of: token)]
            })
        await latch.open()
    }
}

extension SessionEventLog {
    /// Every run message delivered so far, in delivery order.
    var runMessages: [OperationEvent] {
        events.compactMap { event in
            guard case .runMessage(let message) = event else { return nil }
            return message
        }
    }
}
