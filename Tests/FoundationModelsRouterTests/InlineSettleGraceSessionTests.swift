import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Tests the settle period of a session, ``SessionConfiguration/inlineSettleGrace``.
///
/// A background call waits for its own run up to the settle period. A run
/// that ends in that time answers with its own output, and its result is no
/// mail. A run that continues answers with a pending envelope, and its result
/// arrives later as mail, one time.
///
/// A scripted backend calls the background tool of the session in its first
/// answer, and a ``RunLatch`` holds the run. The run plane of each session runs
/// on a `ManualRunClock`, so the settle period ends only when the test
/// advances that clock. No assertion reads a real clock: each wait reads a
/// state until it holds, and the wait ends when the state holds.
@Suite("The settle period of a session decides between the own output and a pending envelope")
struct InlineSettleGraceSessionTests {
    // MARK: - Fixtures

    /// A background tool that states no settle period of its own, so each
    /// call waits for the settle period of the session. Its body waits for
    /// its gate, then returns ``InlineSettleGraceSessionTests/runOutput``.
    struct HostGraceBackgroundTool: Tool, BackgroundTool {
        let name = "host_grace_job"
        let description = "test-only background tool that waits for the settle period of its session"

        /// The latch the body of the run waits on.
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await gate.waitUntilOpen()
            return InlineSettleGraceSessionTests.runOutput
        }
    }

    /// One session over a ``BackgroundingBackend``, with what a test reads.
    struct Fixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: BackgroundingBackend

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The clock of the run plane of the session. The settle period ends
        /// only when the test advances it.
        let clock: ManualRunClock

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The output of the run of ``HostGraceBackgroundTool``.
    static let runOutput = "the job is done"

    /// The prompt of the caller message that starts the run.
    private static let jobPrompt = "run the job"

    /// The settle period of the test of a long run. The test advances the
    /// clock by this period while the run waits for its gate.
    private static let shortGrace: TimeInterval = 0.05

    // MARK: - Helpers

    /// Makes a session with one ``HostGraceBackgroundTool`` and the settle
    /// period `grace`, over a run plane on a new `ManualRunClock`.
    ///
    /// - Parameters:
    ///   - gate: The gate of the run of the tool.
    ///   - grace: The ``SessionConfiguration/inlineSettleGrace`` of the
    ///     session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws, or when the
    ///   container vended no backend. Before it throws, it closes the session
    ///   that it made and removes the directory (rule T1).
    private static func makeFixture(gate: RunLatch, grace: TimeInterval) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "InlineSettleGraceSessionTests")
        let container = BackgroundingLLMContainer()
        let clock = ManualRunClock()
        let (router, profile) = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: directory, runClock: clock)
        }
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [HostGraceBackgroundTool(gate: gate)], inlineSettleGrace: grace))
        let backend = try await RouterTestFixtures.removingDirectoryOnThrow(
            directory, alsoOnThrow: { await session.close() }
        ) {
            try #require(container.lastBackend)
        }
        return Fixture(session: session, backend: backend, router: router, clock: clock, directory: directory)
    }

    /// Ends the fixture: opens `gates`, closes the session and removes the
    /// directory.
    ///
    /// - Parameters:
    ///   - fixture: The fixture to end.
    ///   - gates: The gates of the runs of the session.
    private static func end(_ fixture: Fixture, opening gates: [RunLatch] = []) async {
        for gate in gates { await gate.open() }
        await fixture.session.close()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.router) {}
    }

    // MARK: - The setting

    @Test("a session configuration that names no settle period carries the default of Extras")
    func theConfigurationCarriesTheDefault() {
        #expect(SessionConfiguration().inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
    }

    /// The configuration slice that a session's `index.md` holds keeps the
    /// settle period through an encode and a decode.
    @Test("the record form of a configuration keeps the settle period")
    func thePersistableFormKeepsTheGrace() throws {
        let persistable = SessionConfiguration(inlineSettleGrace: Self.shortGrace).persistable
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONEncoder().encode(persistable))
        #expect(decoded.inlineSettleGrace == Self.shortGrace)
    }

    @Test("a negative settle period acts as zero on the session")
    func aNegativeGraceActsAsZero() async throws {
        let fixture = try await Self.makeFixture(gate: RunLatch(), grace: -1)
        defer { await Self.end(fixture) }
        let actor = try #require(fixture.session as? RoutedSessionActor)
        #expect(actor.inlineSettleGrace == 0)
    }

    // MARK: - A run that continues past the settle period

    @Test("a run longer than the settle period gives a pending envelope, and its result arrives later as mail one time")
    @MainActor
    func aLongRunGivesAPendingEnvelopeAndOneMail() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(gate: gate, grace: Self.shortGrace)
        defer { await Self.end(fixture, opening: [gate]) }

        // The gate stays closed until the call answered. The call waits for
        // its run up to the settle period, and the test then moves the clock
        // past that period, so the run continues past it. A call that ends
        // with no wait on the clock ends the wait of the test too.
        let answering = Task { try await fixture.session.respond(to: Self.jobPrompt) }
        try await fixture.clock.waitForSleepers(atLeast: 1, endingOnEndOf: answering)
        fixture.clock.advance(by: .seconds(Self.shortGrace))
        let answer = try await answering.value
        let envelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: answer))
        #expect(envelope.pending)
        #expect(fixture.backend.toolOutputs == [answer])

        await gate.open()
        let terminal = try await MountFixtures.settledTerminal(
            of: envelope.completionToken, in: fixture.session.runPlane)
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == Self.runOutput)

        // The terminal is mail: it starts one more answer by itself, and its
        // line reaches the model one time over every prompt. The wait also
        // ends when the work of the session ended with no such answer (rule
        // T1).
        try await MailQueueFixtures.waitForPrompts(2, on: fixture.backend, endingWhenWorkEnds: fixture.session)
        #expect(await fixture.session.pumpEnds())
        let prompts = fixture.backend.receivedPrompts
        #expect(prompts.count == 2)
        #expect(prompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
        let line = OperationEventSegment.renderedLine(for: terminal)
        #expect(prompts.joined(separator: "\n").components(separatedBy: line).count - 1 == 1)
        #expect(await fixture.session.outbox.pending().events.isEmpty)
    }

    // MARK: - A run that ends inside the settle period

    @Test("a run shorter than the settle period gives the own output of the tool in band, and no mail")
    @MainActor
    func aShortRunGivesItsOwnOutputAndNoMail() async throws {
        let gate = RunLatch()
        // The gate is open before the call, so the run ends at once. The test
        // never advances the clock, so the settle period never ends: the wait
        // ends when the run settles.
        await gate.open()
        let fixture = try await Self.makeFixture(gate: gate, grace: MountFixtures.manualClockGrace)
        defer { await Self.end(fixture) }

        let answer = try await fixture.session.respond(to: Self.jobPrompt)

        #expect(answer == Self.runOutput)
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: answer) == nil)
        #expect(fixture.backend.toolOutputs == [Self.runOutput])
        // The run settled, and its staged events were withdrawn: no mail
        // waits, and no mail starts one more answer.
        #expect(await fixture.session.runPlane.backgroundRuns().isEmpty)
        // The run settled and its events were withdrawn before the answer
        // came back, so a mail of the run is in the queue before this point
        // or never. A mail in the queue keeps the pump running, so the end
        // of the pump is the point after which one read is the proof.
        #expect(await fixture.session.pumpEnds())
        #expect(fixture.backend.receivedPrompts == [Self.jobPrompt])
        #expect(await fixture.session.outbox.pending().events.isEmpty)
    }
}
