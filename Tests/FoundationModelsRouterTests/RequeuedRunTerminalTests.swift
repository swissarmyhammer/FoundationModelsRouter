import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the run mail that a submission gives back to the queue when its
/// diff had no prompt to attach the mail to
/// (``RoutedSessionActor/requeueUndeliveredRunMail(_:)``).
///
/// The give-back holds only mail that can start a submission now, so the
/// failed submission does not start again at once. The terminal of a run
/// that is still open cannot start a submission now: it goes back with no
/// hold, and the settlement of its run delivers it later, also when no
/// user-type mail comes.
///
/// Everything runs against the scripted backend of
/// ``SessionMessagePumpTests``, so the suite needs no network and no GPU.
@Suite("Run mail that a submission gives back to the queue")
struct RequeuedRunTerminalTests {
    /// The scripted backend of each test.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// One session over a ``Backend``.
    struct Fixture: SessionDirectoryFixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: Backend

        /// The profile that keeps the models of the session resident.
        let profile: LanguageModelProfile

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The prompt of the first caller message. Its answer attaches the outbox
    /// of the session, so later mail wakes the pump.
    private static let firstPrompt = "start the background job"

    /// The prompt of the caller message whose submission fails.
    private static let failingPrompt = "what does the job do"

    /// The detail of the terminal of the background run.
    private static let terminalDetail = "all of the files are done"

    /// The ordinal of the call that fails before it writes an entry.
    private static let failingCall = 2

    /// The ordinal of the call of the answer that the terminal starts.
    private static let terminalAnswerCall = 3

    // MARK: - Helpers

    /// Makes a session over a new backend that follows `script`.
    ///
    /// - Parameter script: What each call of the backend does, by its
    ///   one-based ordinal.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(script: [Int: SessionMessagePumpTests.ScriptedCall]) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "RequeuedRunTerminalTests")
        let backend = Backend(script: script)
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await RouterTestFixtures.resolveStandardProfile(
                over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: directory
            ).profile
        }
        return Fixture(
            session: profile.standard.makeSession(), backend: backend, profile: profile, directory: directory)
    }

    /// The terminal that the run with `token` posts before it settles.
    ///
    /// - Parameter token: The completion token of the run.
    /// - Returns: The `.completed` event.
    private static func terminal(of token: String) -> OperationEvent {
        OperationEvent(
            tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .completed, detail: terminalDetail,
            outcome: .succeeded)
    }

    // MARK: - Tests

    /// The production change that makes this test fail: a give-back that
    /// holds the terminal of a run that is still open. The settlement then
    /// finds the terminal held, and the terminal waits for user-type mail
    /// that never comes.
    @Test("the terminal of an open run that a failed submission gave back is delivered when the run settles, with no user mail")
    func aGivenBackTerminalOfAnOpenRunIsDeliveredAtTheSettle() async throws {
        let fixture = try await Self.makeFixture(script: [Self.failingCall: .fail])
        let latch = RunLatch()
        defer { await fixture.end(opening: [latch]) }
        let session = fixture.session
        let token = await trackFakeRun(on: session.runPlane, latch: latch)
        _ = try await session.respond(to: Self.firstPrompt)
        // The run posts its terminal before it settles, so the terminal rides
        // the next submission, and that submission fails before it writes an
        // entry.
        let terminalId = try await MailQueueFixtures.post(Self.terminal(of: token), to: session)
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: Self.failingPrompt)
        }
        let givenBack = await session.outbox.pending().events.first { $0.id == terminalId }

        await latch.open()
        _ = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
        try await MailQueueFixtures.waitForPrompts(
            Self.terminalAnswerCall, on: fixture.backend, endingWhenWorkEnds: session)

        #expect(givenBack?.isHeld == false)
        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: Self.terminal(of: token))))
        #expect(prompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(await session.outbox.pending().events.isEmpty)
        withExtendedLifetime(fixture.profile) {}
    }

    /// The production change that makes this test fail: a give-back that
    /// holds no mail. The terminal of a settled run can start a submission
    /// now, so the failed submission would start again at once.
    @Test("the terminal of a settled run that a failed submission gave back stays held, and starts no answer by itself")
    func aGivenBackTerminalOfASettledRunStaysHeld() async throws {
        let holdSecondCall = RunLatch()
        let fixture = try await Self.makeFixture(script: [2: .hold(holdSecondCall), 3: .fail])
        let latch = RunLatch()
        defer { await fixture.end(opening: [latch, holdSecondCall]) }
        let session = fixture.session
        let token = await trackFakeRun(on: session.runPlane, latch: latch)
        _ = try await session.respond(to: Self.firstPrompt)
        await latch.open()
        _ = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
        // The second call holds its answer, so the terminal and the failing
        // caller message wait in the queue, and the next take carries both.
        let holding = Task { try await session.respond(to: Self.firstPrompt) }
        try await fixture.backend.changes.wait(
            until: { fixture.backend.prompts.count == 2 }, endingOnEndOf: holding)
        let terminalId = try await MailQueueFixtures.post(Self.terminal(of: token), to: session)
        let failing = Task { try await session.respond(to: Self.failingPrompt) }
        try await session.stateChanges.wait(until: { session.waitingUserMailCount == 1 }, endingOnEndOf: failing)
        await holdSecondCall.open()
        _ = try await holding.value
        await #expect(throws: (any Error).self) { _ = try await failing.value }

        #expect(await session.awaitIdle())
        #expect(await session.outbox.pending().events.first { $0.id == terminalId }?.isHeld == true)
        #expect(fixture.backend.prompts.count == 3)
        withExtendedLifetime(fixture.profile) {}
    }
}
