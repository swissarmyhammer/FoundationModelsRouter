import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The archive of a session (ROUTER-11, session.md section 5.8):
/// ``RouterSessionDirectory/archive(_:by:)`` stops a running turn, takes the
/// session off the live list, writes `archivedAt` to its `index.md`, and
/// sends one `archived`. A second archive gives the summary and sends no
/// event. An archived session takes no message and is never restored, also
/// after a restart.
///
/// The recording router holds the live sessions, over a backend whose first
/// call a latch holds open, so a test archives while the session works. The
/// reading router is a new router over the same recordings folder, standing
/// in for a new process, with a ``FakeSessionLauncher`` that records each
/// restore.
@Suite("RouterSessionDirectory: the archive of a session")
struct RouterSessionDirectoryArchiveTests {
    /// The backend the held turns run on.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The two routers of one test, the held backend of the recording
    /// router, and the launcher of the reading router.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The backend of each session of the recording router.
        let backend: Backend

        /// The latch that holds the first model call of ``backend``.
        let latch: RunLatch

        /// The launcher of ``readingDirectory``.
        let launcher: FakeSessionLauncher

        /// The directory of the recording router, which holds its live
        /// sessions.
        var liveDirectory: RouterSessionDirectory { pair.recordingRouter.sessionDirectory }

        /// The directory of the reading router: the router after a restart.
        var readingDirectory: RouterSessionDirectory { pair.directory }

        /// Vends a live root session of the recording router, and gives both
        /// directories the recording root of the session, so each finds it
        /// on disk once it is not live.
        ///
        /// - Returns: The session.
        func makeLiveRoot() async -> any RoutedSession {
            let session = pair.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
            let root = session.recordingDirectory.deletingLastPathComponent()
            await liveDirectory.useRecordingRoots { [root] }
            await readingDirectory.useRecordingRoots { [root] }
            return session
        }

        /// Starts a held turn on a new live root session: vends it, sends it
        /// the turn prompt, and waits until the held call took the prompt.
        ///
        /// - Returns: The working session and the id of its turn prompt.
        /// - Throws: The refusal of the turn prompt, or ``ConditionNeverHeld``
        ///   when the test is cancelled before the call starts.
        func startHeldTurn() async throws -> (session: any RoutedSession, prompt: MailID) {
            let session = await makeLiveRoot()
            let prompt = try session.send(RouterSessionDirectoryArchiveTests.turnPrompt)
            try await backend.changes.wait(untilAtLeast: RouterSessionDirectoryArchiveTests.firstCall) {
                backend.prompts.count
            }
            return (session, prompt)
        }

        /// Opens the latch, closes `session`, and removes the folders of
        /// the test.
        ///
        /// - Parameter session: The session the test vended.
        func close(_ session: any RoutedSession) async {
            await latch.open()
            await session.close()
            await launcher.closeSessions()
            pair.remove()
        }
    }

    // MARK: - Constants

    /// The prompt that starts the turn a test holds open.
    private static let turnPrompt = "first question"

    /// The text of a message to an archived session.
    private static let text = "Please review the open pull request."

    /// The UI client that archives and sends.
    private static let clientID = "client-a"

    /// The user that archives each session.
    private static let archiver = SessionMessageSender.user(clientID: clientID)

    /// The number of the first call of the held backend.
    private static let firstCall = 1

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Makes the two routers, with a held backend for the recording router
    /// and a launcher for the reading router.
    private static func makeFixture() async throws -> Fixture {
        let latch = RunLatch()
        let backend = Backend(script: [firstCall: .hold(latch)])
        let pair = try await SessionDirectoryRouterPair.make(
            prefix: "RouterSessionDirectoryArchiveTests",
            recordingContainer: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let launcher = FakeSessionLauncher(profile: pair.readingProfile)
        await pair.directory.use(launcher: launcher)
        return Fixture(pair: pair, backend: backend, latch: latch, launcher: launcher)
    }

    /// The record that the `index.md` of `session` holds.
    ///
    /// - Parameter session: A durable session.
    /// - Returns: The record on disk.
    private static func recordOnDisk(of session: any RoutedSession) throws -> SessionRecord {
        try #require(try SessionIndexFile.read(in: session.recordingDirectory))
    }

    /// Sends one UI message to the session `id` through `directory`.
    ///
    /// - Parameters:
    ///   - id: The session id of the target.
    ///   - directory: The directory to send through.
    /// - Returns: The receipts of the send.
    private static func send(to id: ULID, through directory: RouterSessionDirectory) async throws
        -> [SessionSendReceipt]
    {
        try await directory.send(OutgoingSessionMessage(from: archiver, to: .session(id), text: text))
    }

    /// The `refused` receipt of a message to the archived session `id`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The receipt.
    private static func archivedRefusal(of id: ULID) -> SessionSendReceipt {
        SessionSendReceipt(target: id, outcome: .refused, reason: SessionAddressResolution.archivedReason)
    }

    // MARK: - Live

    /// The production change that makes this test fail: an archive that
    /// leaves the turn running, keeps the session on the live list, or
    /// sends no `archived`.
    @Test("an archive of a working session stops its turn, takes it off the live list, and sends archived")
    func anArchiveOfAWorkingSessionStopsItsTurnAndSendsArchived() async throws {
        let fixture = try await Self.makeFixture()
        let (session, prompt) = try await fixture.startHeldTurn()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        let turnEnd = try await session.awaitTerminal(of: prompt)
        let live = try await fixture.liveDirectory.sessions(matching: SessionQuery())
        #expect(turnEnd == .answerFailed(AnswerFailure(mailIds: [prompt], reason: .cancelled)))
        #expect(summary.state == .archived)
        #expect(!summary.isLive)
        #expect(!live.map(\.id).contains(session.id))
        #expect(received == [.archived(id: session.id), Self.marker])
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an archive that
    /// writes no `archivedAt`, or writes it to the live facts only.
    @Test("an archive of a live session writes archivedAt to its index.md")
    func anArchiveOfALiveSessionWritesArchivedAt() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()

        _ = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)

        #expect(try Self.recordOnDisk(of: session).facts.archivedAt != nil)
        #expect(session.facts.archivedAt != nil)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an archive that
    /// leaves the waiting mail of the session in its queue, so the mail
    /// starts a turn when the stopped turn ends.
    @Test("a message that waits for the turn of an archived session is dropped, not delivered")
    func aWaitingMessageOfAnArchivedSessionIsDropped() async throws {
        let fixture = try await Self.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        let receipts = try await Self.send(to: session.id, through: fixture.liveDirectory)
        let waiting = try #require(receipts.first?.messageID)

        _ = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)

        #expect(try await session.awaitTerminal(of: waiting) == .cancelled(waiting))
        #expect(fixture.backend.prompts == [Self.turnPrompt])
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a second archive
    /// that sends `archived` again, or that throws for a session that is no
    /// longer live.
    @Test("a second archive of a session gives its summary and sends no event")
    func aSecondArchiveSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        let first = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)
        let onDisk = try Self.recordOnDisk(of: session)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let second = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(second.id == first.id)
        #expect(second.state == .archived)
        #expect(try Self.recordOnDisk(of: session) == onDisk)
        #expect(received == [Self.marker])
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a live summary
    /// that reads its state from the work tracking alone, so a send
    /// delivers to a live session whose record holds `archivedAt`.
    @Test("a live session whose record holds archivedAt reads archived, and a send to it is refused")
    func aLiveSessionWithArchivedAtIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        let actor = try #require(session as? RoutedSessionActor)
        actor.updateFacts { $0.archivedAt = Date() }

        let receipts = try await Self.send(to: session.id, through: fixture.liveDirectory)

        #expect(receipts == [Self.archivedRefusal(of: session.id)])
        #expect(try await fixture.liveDirectory.summary(of: session.id)?.state == .archived)
        #expect(await session.pendingMessages().isEmpty)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an archive with no
    /// audit record of who archived the session.
    @Test("an archive logs the session and the user that archived it")
    func anArchiveLogsTheArchiver() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()

        try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)
            context.expectLogged(
                containing: "archived",
                metadata: [
                    RouterTelemetry.LogMetadataKey.sessionId: session.id.description,
                    RouterTelemetry.LogMetadataKey.archivedBy: Self.clientID,
                ])
        }
        await fixture.close(session)
    }

    // MARK: - Recorded

    /// The production change that makes this test fail: an archive of a
    /// recorded session that throws `unknownSession`, writes nothing, or
    /// restores the session through the launcher.
    @Test("an archive of a recorded session writes archivedAt to its index.md, sends archived, and never restores it")
    func anArchiveOfARecordedSessionWritesItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.archive(recorded.id, by: Self.archiver)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        let onDisk = try #require(try SessionIndexFile.read(in: recorded.recordingDirectory))
        #expect(onDisk.facts.archivedAt != nil)
        #expect(summary.state == .archived)
        #expect(!summary.isLive)
        #expect(received == [.archived(id: recorded.id), Self.marker])
        #expect(fixture.launcher.restoredIDs.isEmpty)
        #expect(fixture.launcher.requests.isEmpty)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a second archive of
    /// a recorded session that rewrites its `index.md` or sends `archived`
    /// again.
    @Test("a second archive of a recorded session leaves its index.md and sends no event")
    func aSecondArchiveOfARecordedSessionSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        _ = try await fixture.readingDirectory.archive(recorded.id, by: Self.archiver)
        let onDisk = try #require(try SessionIndexFile.read(in: recorded.recordingDirectory))
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.archive(recorded.id, by: Self.archiver)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.state == .archived)
        #expect(try SessionIndexFile.read(in: recorded.recordingDirectory) == onDisk)
        #expect(received == [Self.marker])
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an archive of an id
    /// that no session has that returns a summary or throws another error.
    @Test("an archive of an unknown id throws unknownSession")
    func anArchiveOfAnUnknownIDThrows() async throws {
        let fixture = try await Self.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.readingDirectory.archive(unknown, by: Self.archiver)
        }
        fixture.pair.remove()
    }

    // MARK: - After a restart

    /// The production change that makes this test fail: an archive whose
    /// `archivedAt` does not reach the `index.md`, so a new router reads the
    /// session as idle.
    @Test("after a restart an archived session is found only with includesRecorded, and its state is archived")
    func afterARestartTheSessionIsArchivedAndRecordedOnly() async throws {
        let fixture = try await Self.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)

        let live = try await fixture.readingDirectory.sessions(matching: SessionQuery())
        let recorded = try await SessionDirectorySummaries.summary(
            of: session.id, in: fixture.readingDirectory, matching: SessionQuery(includesRecorded: true))

        #expect(!live.map(\.id).contains(session.id))
        #expect(recorded.state == .archived)
        #expect(!recorded.isLive)
        #expect(try Self.recordOnDisk(of: session).facts.archivedAt != nil)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a send after a
    /// restart that restores the archived session through the launcher.
    @Test("after a restart a send to an archived session is refused as archived, and the launcher gets no call")
    func afterARestartASendIsRefusedAndNotRestored() async throws {
        let fixture = try await Self.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.archiver)

        let receipts = try await Self.send(to: session.id, through: fixture.readingDirectory)

        #expect(receipts == [Self.archivedRefusal(of: session.id)])
        #expect(fixture.launcher.restoredIDs.isEmpty)
        #expect(fixture.launcher.requests.isEmpty)
        await fixture.close(session)
    }
}
