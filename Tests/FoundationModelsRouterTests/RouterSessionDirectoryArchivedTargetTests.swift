import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// A message to an archived session (D204): the message goes to the inbox
/// of the session, as for a recorded session, and the session stays
/// archived. The receipt is `sent` with the note "archived", and the
/// directory sends one `messageQueued`. The message starts no turn and does
/// not restore the session. It reaches the session after an unarchive, when
/// a host opens the session, or at once for a live session.
///
/// Only the full id reaches an archived session: a short id or a slug does
/// not match it (D199 (d)).
///
/// Each test uses the fixture of ``RouterSessionDirectoryArchiveTests``. The
/// live directory archives, sends and unarchives.
@Suite("RouterSessionDirectory: a message to an archived session")
struct RouterSessionDirectoryArchivedTargetTests {
    /// The fixture of the archive suite.
    typealias Fixture = RouterSessionDirectoryArchiveTests.Fixture

    // MARK: - Constants

    /// The user that sends, archives and unarchives.
    private static let user = SessionMessageSender.user(clientID: "client-a")

    /// The text of the message to the archived session.
    private static let text = "Please review the open pull request."

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Vends a live root session and archives it, so it is a recorded
    /// session that is not live.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The session that the archive took off the live list.
    /// - Throws: The error of the archive.
    private static func archivedSession(in fixture: Fixture) async throws -> any RoutedSession {
        let session = await fixture.makeLiveRoot()
        _ = try await fixture.liveDirectory.archive(session.id, by: user)
        return session
    }

    /// Vends a live root session whose record holds `archivedAt`, as after a
    /// `session/load` of an archived session, and opens the latch of the
    /// backend, so a turn of the session does not wait.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The live archived session.
    /// - Throws: The `#require` failure when the session is not a
    ///   ``RoutedSessionActor``.
    private static func liveArchivedSession(in fixture: Fixture) async throws -> any RoutedSession {
        await fixture.latch.open()
        let session = await fixture.makeLiveRoot()
        let actor = try #require(session as? RoutedSessionActor)
        actor.updateFacts { $0.archivedAt = MillisecondDate.rounded(Date()) }
        return session
    }

    /// Sends one UI message with no source session to the session `id`
    /// through the live directory.
    ///
    /// - Parameters:
    ///   - id: The session id of the target.
    ///   - fixture: The fixture of the test.
    /// - Returns: The receipts of the send.
    /// - Throws: The error of the send.
    private static func send(to id: ULID, in fixture: Fixture) async throws -> [SessionSendReceipt] {
        try await fixture.liveDirectory.send(OutgoingSessionMessage(from: user, to: .session(id), text: text))
    }

    /// Sends one message to the session `id` as ``send(to:in:)`` does, and
    /// gives the id of the message.
    ///
    /// - Parameters:
    ///   - id: The session id of the target.
    ///   - fixture: The fixture of the test.
    /// - Returns: The id of the message.
    /// - Throws: The error of the send, or the `#require` failure when the
    ///   receipt has no message id.
    private static func sendMessage(to id: ULID, in fixture: Fixture) async throws -> MailID {
        try #require(try await send(to: id, in: fixture).first?.messageID)
    }

    /// The `messageQueued` events of the message `id` in `events`.
    ///
    /// - Parameters:
    ///   - id: The id of a message.
    ///   - events: The events a test read.
    /// - Returns: The queued messages with the id.
    private static func queued(_ id: MailID, in events: [SessionDirectoryEvent]) -> [SessionMessage] {
        events.compactMap { event in
            guard case .messageQueued(let message) = event, message.id == id else { return nil }
            return message
        }
    }

    // MARK: - A recorded archived session

    /// The production change that makes this test fail: a resolver that
    /// refuses an archived target, or a send that gives no note.
    @Test("a send by full id to an archived session is sent with the note archived")
    func aSendByFullIDIsSentWithTheNoteArchived() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)

        let receipts = try await Self.send(to: session.id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        #expect(
            receipts == [
                SessionSendReceipt(
                    messageID: messageID, target: session.id, outcome: .sent,
                    reason: RouterSessionDirectory.archivedNote)
            ])
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a send to an
    /// archived session that gives no `messageQueued`, or two.
    @Test("a send to an archived session sends one messageQueued")
    func aSendToAnArchivedSessionSendsOneMessageQueued() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let messageID = try await Self.sendMessage(to: session.id, in: fixture)
        fixture.liveDirectory.emit(Self.marker)

        #expect(Self.queued(messageID, in: await events.next(through: Self.marker)).count == 1)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a send to an
    /// archived session that writes no file in its `inbox/` folder.
    @Test("a send to an archived session writes the message as a file in its inbox")
    func aSendToAnArchivedSessionWritesAnInboxFile() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)

        let messageID = try await Self.sendMessage(to: session.id, in: fixture)

        #expect(try RouterSessionDirectoryArchiveMailTests.inboxFile(messageID, of: session).text == Self.text)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a send that
    /// unarchives or restores its archived target.
    @Test("after a send an archived session stays archived and is not restored")
    func anArchivedSessionStaysArchived() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)

        _ = try await Self.sendMessage(to: session.id, in: fixture)

        let summary = try await SessionDirectorySummaries.summary(
            of: session.id, in: fixture.liveDirectory, matching: SessionQuery(includesRecorded: true))
        #expect(summary.state == .archived)
        #expect(!summary.isLive)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an inbox file of an
    /// archived session that the open after an unarchive does not deliver.
    @Test("after an unarchive and an open, the message reaches the session")
    func afterAnUnarchiveAndAnOpenTheMessageReachesTheSession() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)
        let messageID = try await Self.sendMessage(to: session.id, in: fixture)
        await fixture.latch.open()

        let (launcher, _, delivered) = try await RouterSessionDirectoryArchiveMailTests.reopen(
            session.id, awaiting: messageID, in: fixture)

        #expect(delivered?.text == Self.text)
        await launcher.closeSessions()
        await fixture.close(session)
    }

    // MARK: - A live archived session

    /// The production change that makes this test fail: a scan of the inbox
    /// that delivers a file to a live session whose record holds
    /// `archivedAt`, so the message starts a turn of an archived session.
    @Test("a live archived session keeps the message in its inbox and starts no turn")
    func aLiveArchivedSessionKeepsTheMessageInItsInbox() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.liveArchivedSession(in: fixture)
        let messageID = try await Self.sendMessage(to: session.id, in: fixture)

        await fixture.liveDirectory.scanInbox(of: session.id)

        #expect(try RouterSessionDirectoryArchiveMailTests.inboxFile(messageID, of: session).text == Self.text)
        #expect(await session.pendingMessages().isEmpty)
        #expect(try await fixture.liveDirectory.summary(of: session.id)?.state == .archived)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an unarchive of a
    /// live session that leaves the files of its inbox where they are, so
    /// the message waits until the next open.
    @Test("an unarchive of a live archived session delivers the message of its inbox")
    func anUnarchiveOfALiveArchivedSessionDeliversTheMessage() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.liveArchivedSession(in: fixture)
        let messageID = try await Self.sendMessage(to: session.id, in: fixture)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        _ = try await fixture.liveDirectory.unarchive(session.id, by: Self.user)
        await session.awaitIdle()
        fixture.liveDirectory.emit(Self.marker)

        let read = await events.next(through: Self.marker)
        #expect(RouterSessionDirectoryArchiveMailTests.delivery(of: messageID, in: read)?.text == Self.text)
        await fixture.close(session)
    }

    // MARK: - The full id only

    /// The production change that makes this test fail: a summary of an
    /// archived session that does not read archived, so a short id or a
    /// slug names the archived session (D199 (d)).
    @Test("a short id or a slug that only an archived session has matches no session")
    func aShortIDOrASlugMatchesNoArchivedSession() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let session = try await Self.archivedSession(in: fixture)
        let summaries = try await fixture.liveDirectory.sessions(matching: SessionQuery(includesRecorded: true))
        let archived = try #require(summaries.first { $0.id == session.id })

        let resolutions = [archived.shortID, archived.slug].map {
            SessionReference.resolve($0, sourceFolder: nil, among: summaries)
        }

        #expect(resolutions == [.none, .none])
        await fixture.close(session)
    }
}
