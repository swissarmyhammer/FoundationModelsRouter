import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The recap maker of the session directory of a router (D206): after a turn
/// with a tool call and the idle time, one call of the `flash` slot in a new
/// blank session writes the recap to the record of the session, and the
/// directory sends `factsChanged`.
///
/// The sessions run over the production backend and a scripted model that
/// calls one tool in each turn, then answers. The blank session of the
/// container with no tools is the fake flash model (``RecapProbeContainer``).
/// The router gives its manual run clock to the directory, so the idle time
/// passes with no sleep.
@Suite("RouterSessionDirectory: the recap of a session after a turn with a tool call")
struct RouterSessionDirectoryRecapTests {
    /// The container of each test.
    fileprivate typealias Container = RecapProbeContainer<LiveBackendContainer<ScriptedRoundsModel>>

    /// The parts of one test.
    struct Fixture {
        /// The folders of the test.
        let directories: TestDirectories

        /// The router of the sessions.
        let router: Router

        /// The resolved profile of ``router``.
        let profile: LanguageModelProfile

        /// The run clock of ``router`` and of its directory.
        let clock: ManualRunClock

        /// The container of the sessions and of the fake flash model.
        fileprivate let container: Container

        /// The log of each call of the model of the sessions.
        let log: RenderProbeLog

        /// The directory under test.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// The fake flash model.
        var flash: RecapProbeBackend { container.recap }

        /// Vends a root session with the tool that the scripted model calls.
        ///
        /// - Returns: The session.
        func makeRoot() -> any RoutedSession {
            profile.standard.makeSession(configuration: SessionConfiguration(tools: [MarkerEmittingTool()]))
        }

        /// Runs one turn of `session`, and waits until the directory sends
        /// its `stateChanged` to idle. The directory gives the end of the
        /// turn to its recapper before it sends that event.
        ///
        /// - Parameter session: A live session of ``directory``.
        /// - Throws: What the answer throws.
        func runTurn(of session: any RoutedSession) async throws {
            var events = directory.events().makeAsyncIterator()
            _ = try await session.respond(to: RouterSessionDirectoryRecapTests.prompt)
            // Rule T1 quiet state: a directory that never sends the idle
            // state hangs here, and the test never passes.
            while let event = await events.next(), !Self.isIdle(event, of: session.id) {}
        }

        /// Moves the clock past the idle time, and waits until no recap job
        /// of the directory waits, queues or runs.
        ///
        /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
        func passTheIdleTime() async throws {
            clock.advance(by: SessionRecapper.idleTime)
            try await directory.recapper.jobChanges.wait(until: { directory.recapper.jobCount == 0 })
        }

        /// Closes `sessions` and removes the folders of the test.
        ///
        /// - Parameter sessions: The sessions of the test.
        func end(_ sessions: [any RoutedSession]) async {
            for session in sessions {
                await session.close()
            }
            directories.remove()
        }

        /// Whether `event` is the `stateChanged` to idle of the session `id`.
        ///
        /// - Parameters:
        ///   - event: An event of the directory.
        ///   - id: The session id.
        /// - Returns: `true` for that event.
        private static func isIdle(_ event: SessionDirectoryEvent, of id: ULID) -> Bool {
            guard case .stateChanged(let changed, .idle, _) = event else { return false }
            return changed == id
        }
    }

    /// The folders that the recap policy of a test was asked about.
    private final class PolicyLog: Sendable {
        /// The folders, behind one lock.
        private let folders = Mutex<[URL]>([])

        /// The folders so far.
        var all: [URL] { folders.withLock { $0 } }

        /// Records `folder`, and turns the recap on.
        ///
        /// - Parameter folder: The working folder of a session.
        /// - Returns: `true`.
        func isRecapOn(in folder: URL) -> Bool {
            folders.withLock { $0.append(folder) }
            return true
        }
    }

    // MARK: - Constants

    /// The prompt of each turn.
    static let prompt = "look up the marker of step one"

    /// The output of the fake flash model.
    private static let recap = "Looked up the marker of step one; the session waits for the next step."

    /// The arguments of the scripted tool call of each turn.
    private static let callArguments = #"{"value":"one"}"#

    /// The user that archives and unarchives.
    private static let user = SessionMessageSender.user(clientID: "recap-test-client")

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Makes a router whose sessions call the marker tool in each turn, with
    /// a manual run clock.
    ///
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture() async throws -> Fixture {
        let log = RenderProbeLog()
        let model = ScriptedRoundsModel(
            log: log, rounds: [[ScriptedRoundCall(name: MarkerEmittingTool.toolName, arguments: callArguments)]],
            replaysEachTurn: true)
        let flash = RecapProbeBackend(output: recap, changes: ChangeSignal())
        let container = Container(sessions: LiveBackendContainer(model: model), recap: flash)
        let directories = TestDirectories(prefix: "RouterSessionDirectoryRecapTests")
        let clock = ManualRunClock()
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directories.cacheDir, runClock: clock, recordingsDir: directories.recordingsDir)
        // The recording root, as a host gives it, so the unarchive finds the
        // archived session that is not live.
        let root = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: directories.recordingsDir)
        await router.sessionDirectory.useRecordingRoots { [root] }
        return Fixture(
            directories: directories, router: router, profile: profile, clock: clock, container: container, log: log)
    }

    // MARK: - The call

    /// The production change that makes this test fail: a directory that
    /// gives the events of its sessions to no recapper.
    @Test("a turn with a tool call and the idle time make one call of the flash model")
    func aTurnWithAToolCallMakesOneFlashCall() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)

        try await fixture.passTheIdleTime()

        #expect(fixture.flash.calls.count == 1)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a session that
    /// gives the recapper no delivered prompt.
    @Test("the input of the recap call holds the user prompt of the turn")
    func theInputHoldsTheUserPrompt() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)

        try await fixture.passTheIdleTime()

        #expect(fixture.flash.calls.first?.prompt.contains(Self.prompt) == true)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a recap call with
    /// the sampling mode of the profile, not temperature 0.
    @Test("the recap call decodes greedy")
    func theRecapCallDecodesGreedy() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)

        try await fixture.passTheIdleTime()

        #expect(fixture.container.samplingModes.all == [.greedy])
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a recap that is not
    /// written to the record.
    @Test("the recap and its time go to the record of the session")
    func theRecapGoesToTheRecord() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)

        try await fixture.passTheIdleTime()

        let facts = try SessionRecordFixtures.recordOnDisk(in: session.recordingDirectory).facts
        #expect(facts.recap == Self.recap && facts.recapAt != nil)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a recap write that
    /// sends no event.
    @Test("the recap write sends factsChanged with the recap")
    func theRecapWriteSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)
        var events = fixture.directory.events().makeAsyncIterator()

        try await fixture.passTheIdleTime()
        fixture.directory.emit(Self.marker)

        let recaps = await events.next(through: Self.marker).compactMap { event -> String? in
            guard case .factsChanged(let summary) = event else { return nil }
            return summary.recap
        }
        #expect(recaps == [Self.recap])
        await fixture.end([session])
    }

    // MARK: - The session itself

    /// The production change that makes this test fail: a recap call on the
    /// backend of the session, which changes its transcript.
    @Test("the transcript of the session is the same before and after a recap")
    func theTranscriptIsTheSameAfterARecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)
        let before = await session.transcript

        try await fixture.passTheIdleTime()

        #expect(await session.transcript == before)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a recap call on the
    /// model of the session, with its KV cache.
    @Test("the model of the session gets no call from a recap")
    func theModelOfTheSessionGetsNoCall() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)
        let callsBefore = fixture.log.renders.count

        try await fixture.passTheIdleTime()

        #expect(fixture.log.renders.count == callsBefore)
        await fixture.end([session])
    }

    // MARK: - No recap

    /// The production change that makes this test fail: an archive that
    /// leaves the wait of the session.
    @Test("an archive during the wait cancels the wait")
    func anArchiveCancelsTheWait() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)

        try await fixture.directory.archive(session.id, by: Self.user)

        #expect(fixture.directory.recapper.jobCount == 0)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: an unarchive that
    /// starts a recap.
    @Test("an unarchive starts no recap")
    func anUnarchiveStartsNoRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        try await fixture.runTurn(of: session)
        try await fixture.directory.archive(session.id, by: Self.user)

        try await fixture.directory.unarchive(session.id, by: Self.user)
        try await fixture.passTheIdleTime()

        #expect(fixture.flash.calls.isEmpty)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a recap of a
    /// subagent.
    @Test("a subagent gets no recap")
    func aSubagentGetsNoRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.makeRoot()
        fixture.directory.register(session, kind: .subagent, parentID: ULID.generate())

        try await fixture.runTurn(of: session)

        #expect(fixture.directory.recapper.jobCount == 0)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a directory that
    /// reads no recap policy.
    @Test("the recap policy off starts no recap")
    func thePolicyOffStartsNoRecap() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.directory.useRecapPolicy { _ in false }
        let session = fixture.makeRoot()

        try await fixture.runTurn(of: session)

        #expect(fixture.directory.recapper.jobCount == 0)
        await fixture.end([session])
    }

    /// The production change that makes this test fail: a policy that gets
    /// another folder than the working folder of the session.
    @Test("the recap policy gets the working folder of the session")
    func thePolicyGetsTheWorkingFolder() async throws {
        let fixture = try await Self.makeFixture()
        let policy = PolicyLog()
        await fixture.directory.useRecapPolicy { policy.isRecapOn(in: $0) }
        let session = fixture.makeRoot()

        try await fixture.runTurn(of: session)

        #expect(policy.all.contains(session.workingDirectory))
        await fixture.end([session])
    }
}

/// The flash model is busy while a session on it has a running turn (D206):
/// the recap call waits for the end of that turn.
@Suite("RouterSessionDirectory: the flash model is busy while a session on it works")
struct RouterSessionDirectoryRecapBusyTests {
    /// The backend of each session.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The number of the call that the test holds.
    private static let firstCall = 1

    /// The prompt of the held turn.
    private static let prompt = "run the job"

    /// Starts a held turn of a session that `vend` makes, waits until the
    /// directory sends its `stateChanged` to working, and tells whether the
    /// flash model of the profile is busy then.
    ///
    /// - Parameter vend: Makes the session from the profile.
    /// - Returns: Whether the flash model is busy during the turn.
    /// - Throws: What the resolve of the profile or the send throws.
    private static func isFlashBusy(
        duringATurnOf vend: (LanguageModelProfile) -> any RoutedSession
    ) async throws -> Bool {
        let latch = RunLatch()
        let directories = TestDirectories(prefix: "RouterSessionDirectoryRecapBusyTests")
        defer { directories.remove() }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: Backend(script: [firstCall: .hold(latch)])),
            cacheDir: directories.cacheDir)
        var events = router.sessionDirectory.events().makeAsyncIterator()
        let session = vend(profile)
        _ = try session.send(prompt)
        let working = SessionDirectoryEvent.stateChanged(id: session.id, state: .working, lastSummary: nil)
        // Rule T1 quiet state: a directory that never sends the working
        // state hangs here, and the test never passes.
        while let event = await events.next(), event != working {}
        let isBusy = router.sessionDirectory.isRecapModelBusy(profile.flash.chosen)
        await SessionFixtureLifecycle.close(session, opening: [latch])
        return isBusy
    }

    /// The production change that makes this test fail: a busy check that
    /// reads no running turn.
    @Test("a running turn of a session on the flash model makes the flash model busy")
    func aTurnOnTheFlashModelMakesItBusy() async throws {
        #expect(try await Self.isFlashBusy(duringATurnOf: { $0.flash.makeSession() }))
    }

    /// The production change that makes this test fail: a busy check that
    /// counts a running turn on any model.
    @Test("a running turn of a session on another model leaves the flash model free")
    func aTurnOnAnotherModelLeavesTheFlashModelFree() async throws {
        #expect(try await Self.isFlashBusy(duringATurnOf: { $0.standard.makeSession() }) == false)
    }
}
