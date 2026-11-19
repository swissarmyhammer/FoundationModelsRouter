import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The unarchive of a session (D204):
/// ``RouterSessionDirectory/unarchive(_:by:)`` removes `archivedAt` from the
/// record of the session, and sends `stateChanged` with `idle`, then
/// `unarchived`. A recorded session stays recorded and not live. A live
/// session whose record holds `archivedAt` stays live. A session that is not
/// archived gives its summary, with no event and no write. Each summary
/// holds the time of the archive in ``SessionSummary/archivedAt``.
///
/// Each test uses the fixture of ``RouterSessionDirectoryArchiveTests``, and
/// the inbox test uses the fixture of ``RouterSessionDirectoryDeliveryTests``.
@Suite("RouterSessionDirectory: the unarchive of a session")
struct RouterSessionDirectoryUnarchiveTests {
    /// The fixture of the archive suite.
    typealias Fixture = RouterSessionDirectoryArchiveTests.Fixture

    // MARK: - Constants

    /// The UI client that archives and unarchives.
    private static let clientID = "client-a"

    /// The user that archives and unarchives each session.
    private static let user = SessionMessageSender.user(clientID: clientID)

    /// The text of the message in the inbox of an archived session.
    private static let text = "Please review the open pull request."

    /// The count of the events of one unarchive: `stateChanged` and
    /// `unarchived`.
    private static let unarchiveEventCount = 2

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Records a closed root session, gives the reading directory its root,
    /// and archives it there.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The id and the recording directory of the archived session.
    /// - Throws: The error of the archive.
    private static func recordArchivedRoot(in fixture: Fixture) async throws
        -> (id: ULID, recordingDirectory: URL)
    {
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        _ = try await fixture.readingDirectory.archive(recorded.id, by: user)
        return recorded
    }

    /// Vends a live root session and writes `archivedAt` to its record, as a
    /// client does that opens an archived session with `session/load`.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The live session, whose record holds `archivedAt`.
    /// - Throws: The `#require` failure when the session is not a
    ///   ``RoutedSessionActor``.
    private static func makeArchivedLiveRoot(in fixture: Fixture) async throws -> any RoutedSession {
        let session = await fixture.makeLiveRoot()
        let actor = try #require(session as? RoutedSessionActor)
        actor.updateFacts { $0.archivedAt = MillisecondDate.rounded(Date()) }
        return session
    }

    /// The two events of the unarchive of the session `id`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: `stateChanged` with `idle`, then `unarchived`.
    private static func unarchiveEvents(of id: ULID) -> [SessionDirectoryEvent] {
        [.stateChanged(id: id, state: .idle, lastSummary: nil), .unarchived(id: id)]
    }

    // MARK: - Recorded

    /// The production change that makes this test fail: an unarchive of a
    /// recorded session that leaves `archivedAt` in its `index.md`.
    @Test("an unarchive of a recorded session removes archivedAt from its index.md")
    func anUnarchiveOfARecordedSessionRemovesArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = try await Self.recordArchivedRoot(in: fixture)

        _ = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)

        #expect(try SessionRecordFixtures.recordOnDisk(in: recorded.recordingDirectory).facts.archivedAt == nil)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive of a
    /// recorded session that gives a summary that is archived, or live.
    @Test("an unarchive of a recorded session gives an idle summary that is not live")
    func anUnarchiveOfARecordedSessionGivesAnIdleSummary() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = try await Self.recordArchivedRoot(in: fixture)

        let summary = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)

        #expect(summary.state == .idle)
        #expect(!summary.isLive)
        #expect(fixture.launcher.restoredIDs.isEmpty)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive of a
    /// recorded session that sends no event, or the events in another order.
    @Test("an unarchive of a recorded session sends stateChanged with idle, then unarchived")
    func anUnarchiveOfARecordedSessionSendsTheEvents() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = try await Self.recordArchivedRoot(in: fixture)
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        _ = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)
        let received = await events.next(count: Self.unarchiveEventCount)

        #expect(received == Self.unarchiveEvents(of: recorded.id))
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive with no
    /// audit record of who unarchived the session.
    @Test("an unarchive logs the session and the user that unarchived it")
    func anUnarchiveLogsTheUnarchiver() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = try await Self.recordArchivedRoot(in: fixture)

        try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)
            context.expectLogged(
                containing: "unarchived",
                metadata: [
                    RouterTelemetry.LogMetadataKey.sessionId: recorded.id.description,
                    RouterTelemetry.LogMetadataKey.unarchivedBy: Self.clientID,
                ])
        }
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive of a
    /// recorded session that is not archived that rewrites its `index.md`
    /// or sends an event.
    @Test("an unarchive of a recorded session that is not archived writes nothing and sends no event")
    func anUnarchiveOfARecordedSessionThatIsNotArchivedChangesNothing() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        _ = try await fixture.readingDirectory.summary(of: recorded.id)
        let onDisk = try SessionRecordFixtures.recordOnDisk(in: recorded.recordingDirectory)
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(count: 1)

        #expect(summary.state == .idle)
        #expect(try SessionRecordFixtures.recordOnDisk(in: recorded.recordingDirectory) == onDisk)
        #expect(received == [Self.marker])
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive of an
    /// id that no session has that returns a summary or throws another error.
    @Test("an unarchive of an unknown id throws unknownSession")
    func anUnarchiveOfAnUnknownIDThrows() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.readingDirectory.unarchive(unknown, by: Self.user)
        }
        fixture.pair.remove()
    }

    // MARK: - Live

    /// The production change that makes this test fail: an unarchive of a
    /// live session that leaves `archivedAt` in its record or in its
    /// `index.md`.
    @Test("an unarchive of a live session whose record holds archivedAt removes it from the record and the index.md")
    func anUnarchiveOfALiveSessionRemovesArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.makeArchivedLiveRoot(in: fixture)

        _ = try await fixture.liveDirectory.unarchive(session.id, by: Self.user)

        #expect(session.facts.archivedAt == nil)
        #expect(try SessionRecordFixtures.recordOnDisk(in: session.recordingDirectory).facts.archivedAt == nil)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an unarchive of a
    /// live session that gives the state archived, or that takes the
    /// session off the live list.
    @Test("an unarchive of a live session whose record holds archivedAt gives an idle live summary")
    func anUnarchiveOfALiveSessionGivesAnIdleLiveSummary() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.makeArchivedLiveRoot(in: fixture)

        let summary = try await fixture.liveDirectory.unarchive(session.id, by: Self.user)

        #expect(summary.state == .idle)
        #expect(summary.isLive)
        #expect(try await fixture.liveDirectory.summary(of: session.id)?.state == .idle)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an unarchive of a
    /// live session that sends no event, or the events in another order.
    @Test("an unarchive of a live session whose record holds archivedAt sends stateChanged with idle, then unarchived")
    func anUnarchiveOfALiveSessionSendsTheEvents() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.makeArchivedLiveRoot(in: fixture)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        _ = try await fixture.liveDirectory.unarchive(session.id, by: Self.user)
        let received = await events.next(count: Self.unarchiveEventCount)

        #expect(received == Self.unarchiveEvents(of: session.id))
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an unarchive of a
    /// live session that is not archived that sends an event.
    @Test("an unarchive of a live session that is not archived sends no event")
    func anUnarchiveOfALiveSessionThatIsNotArchivedSendsNoEvent() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = await fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.unarchive(session.id, by: Self.user)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(count: 1)

        #expect(summary.isLive)
        #expect(received == [Self.marker])
        await fixture.close(session)
    }

    // MARK: - The time of the archive

    /// The production change that makes this test fail: a summary of an
    /// archive of a live session with no `archivedAt`, or with a time that
    /// is not the time on disk.
    @Test("the summary of an archive of a live session holds the archivedAt of its index.md")
    func theSummaryOfALiveArchiveHoldsArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = await fixture.makeLiveRoot()

        let summary = try await fixture.liveDirectory.archive(session.id, by: Self.user)

        let onDisk = try #require(
            try SessionRecordFixtures.recordOnDisk(in: session.recordingDirectory).facts.archivedAt)
        #expect(summary.archivedAt == onDisk)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a live summary that
    /// does not read `archivedAt` from the record of the session.
    @Test("the live summary of a session whose record holds archivedAt holds that time")
    func theLiveSummaryHoldsArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.makeArchivedLiveRoot(in: fixture)

        let summary = try await fixture.liveDirectory.summary(of: session.id)

        #expect(summary?.archivedAt == session.facts.archivedAt)
        #expect(summary?.archivedAt != nil)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a recorded summary
    /// that does not read `archivedAt` from the `index.md`, so the time is
    /// lost after a restart.
    @Test("after a restart the recorded summary of an archived session holds the archivedAt of its index.md")
    func afterARestartTheRecordedSummaryHoldsArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = await fixture.makeLiveRoot()
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)

        let recorded = try await fixture.readingDirectory.summary(of: session.id)

        let onDisk = try #require(
            try SessionRecordFixtures.recordOnDisk(in: session.recordingDirectory).facts.archivedAt)
        #expect(recorded?.archivedAt == onDisk)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an unarchive that
    /// gives a summary that still holds the time of the archive.
    @Test("after an unarchive the summary has no archivedAt")
    func afterAnUnarchiveTheSummaryHasNoArchivedAt() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let recorded = try await Self.recordArchivedRoot(in: fixture)

        let summary = try await fixture.readingDirectory.unarchive(recorded.id, by: Self.user)

        #expect(summary.archivedAt == nil)
        #expect(try await fixture.readingDirectory.summary(of: recorded.id)?.archivedAt == nil)
        fixture.pair.remove()
    }

    // MARK: - The inbox

    /// The production change that makes this test fail: an archive or an
    /// unarchive that removes the inbox of a recorded session, so a host
    /// that opens the unarchived session finds no message (D199 (f)).
    @Test("an unarchived recorded session reads the files of its inbox when a host opens it")
    func anUnarchivedSessionReadsItsInboxWhenItOpens() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let (id, folder) = try await fixture.recordClosedSessionWithFolder()
        let messageID = MailID()
        let message = SessionInboxMessage(
            id: messageID, from: .user(clientID: SessionInboxFile.defaultUserClientID), inReplyTo: nil,
            chainDepth: 1, text: Self.text, unknownKeys: [:])
        try SessionInboxFile.write(message, to: folder, maxMessageBytes: SessionMessageLimits().maxMessageBytes)
        _ = try await fixture.directory.archive(id, by: Self.user)
        _ = try await fixture.directory.unarchive(id, by: Self.user)
        var events = fixture.directory.events().makeAsyncIterator()

        let opened = try await fixture.profile.standard.restoreSession(id: id).session

        #expect(await events.nextDelivery(of: messageID) != nil)
        #expect(await opened.awaitIdle())
        #expect(await opened.transcript.promptTexts.map { $0.contains(Self.text) } == [true])
        await fixture.close([opened])
    }
}
