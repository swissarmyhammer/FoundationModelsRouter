import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The mail of an archived session (D204): an archive keeps each message
/// that waits in the queue of the session as an unread message of its inbox,
/// a file in the `inbox/` folder of a durable session, with its sender, its
/// client id, its source session and its header. The files of the inbox stay.
/// No `messageDelivered` comes at the archive. The message reaches the session
/// when a host opens it after an unarchive, and `messageDelivered` comes then.
///
/// A memory-only session has no `inbox/` folder, and it cannot open again
/// after its archive. Its waiting mail ends cancelled, with no
/// `messageDelivered`.
///
/// Each test of a durable session uses the fixture of
/// ``RouterSessionDirectoryArchiveTests``. The live directory archives,
/// unarchives, and sees the open of the session through a
/// ``FakeSessionLauncher`` of the recording router, because a router finds
/// the recordings of its own id only. The reading directory (the router
/// after a restart) reads the inbox from the disk.
@Suite("RouterSessionDirectory: an archive keeps the waiting mail")
struct RouterSessionDirectoryArchiveMailTests {
    /// The fixture of the archive suite.
    typealias Fixture = RouterSessionDirectoryArchiveTests.Fixture

    // MARK: - Constants

    /// The UI client that sends, archives and unarchives.
    private static let clientID = "client-a"

    /// The user that sends, archives and unarchives.
    private static let user = SessionMessageSender.user(clientID: clientID)

    /// The text of the message that waits at the archive.
    private static let text = "Please review the open pull request."

    /// The chain depth of a message that no message answers.
    private static let firstChainDepth = 1

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Sends one UI message to the session `id` through the live directory
    /// of `fixture`, and gives the id of the message.
    ///
    /// - Parameters:
    ///   - id: The session id of the target.
    ///   - source: The source session of the message, or `nil`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The id of the message.
    /// - Throws: The error of the send, or the `#require` failure when the
    ///   receipt has no message id.
    private static func sendMessage(to id: ULID, from source: ULID? = nil, in fixture: Fixture) async throws
        -> MailID
    {
        let receipts = try await fixture.liveDirectory.send(
            OutgoingSessionMessage(from: user, to: .session(id), text: text, sourceSession: source))
        return try #require(receipts.first?.messageID)
    }

    /// The message of the inbox file `id` of `session`.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - session: A durable session.
    /// - Returns: The message of the file.
    /// - Throws: The error of the read of the file.
    static func inboxFile(_ id: MailID, of session: any RoutedSession) throws -> SessionInboxMessage {
        try SessionInboxFile.read(
            SessionInboxFile.url(of: id, in: session.recordingDirectory),
            maxMessageBytes: SessionMessageLimits().maxMessageBytes)
    }

    /// Whether `events` holds a `messageDelivered` event.
    ///
    /// - Parameter events: The events a test read.
    /// - Returns: `true` when one of `events` is `messageDelivered`.
    private static func holdsDelivery(_ events: [SessionDirectoryEvent]) -> Bool {
        events.contains { event in
            guard case .messageDelivered = event else { return false }
            return true
        }
    }

    /// The message `id` of the `messageDelivered` events in `events`.
    ///
    /// - Parameters:
    ///   - id: The id of a message.
    ///   - events: The events a test read.
    /// - Returns: The delivered message, or `nil` when `events` holds no
    ///   `messageDelivered` of `id`.
    static func delivery(of id: MailID, in events: [SessionDirectoryEvent]) -> SessionMessage? {
        for event in events {
            if case .messageDelivered(let message) = event, message.id == id { return message }
        }
        return nil
    }

    /// Unarchives the session `id` through the live directory, opens it with
    /// a launcher of the recording router, and gives the message `messageID`
    /// when the directory delivered it to the opened session.
    ///
    /// Each read has an end, also when the message does not reach the
    /// session. The helper scans the inbox of the opened session itself,
    /// because the first scan of the watcher runs in a task that the test
    /// does not wait for. Then it waits until the opened session is idle:
    /// the turn of the delivered message is over, or no turn started. Then
    /// it emits a marker and reads the events through the marker. The
    /// `messageDelivered` of a message that reached the session comes before
    /// the end of its turn, thus before the marker.
    ///
    /// - Parameters:
    ///   - id: The session id of an archived session.
    ///   - messageID: The id of a message in its inbox.
    ///   - fixture: The fixture of the test.
    /// - Returns: The launcher, the opened session, and the delivered
    ///   message, or `nil` when no `messageDelivered` of `messageID` came
    ///   before the session was idle.
    /// - Throws: The error of the unarchive or of the restore.
    static func reopen(_ id: ULID, awaiting messageID: MailID, in fixture: Fixture) async throws
        -> (launcher: FakeSessionLauncher, opened: any RoutedSession, delivered: SessionMessage?)
    {
        let launcher = FakeSessionLauncher(profile: fixture.pair.recordingProfile)
        _ = try await fixture.liveDirectory.unarchive(id, by: user)
        var events = fixture.liveDirectory.events().makeAsyncIterator()
        let opened = try await launcher.restoreSession(id: id)
        await fixture.liveDirectory.scanInbox(of: id)
        await opened.awaitIdle()
        fixture.liveDirectory.emit(marker)
        return (launcher, opened, delivery(of: messageID, in: await events.next(through: marker)))
    }

    // MARK: - The queued message

    /// The production change that makes this test fail: an archive that
    /// drops the queued mail, so the inbox folder holds no file for it.
    @Test("a queued message stays as an inbox file with its sender and its client id")
    func aQueuedMessageStaysAsAnInboxFile() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        let messageID = try await Self.sendMessage(to: session.id, in: fixture)

        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)

        let expected = SessionInboxMessage(
            id: messageID, from: Self.user, inReplyTo: nil, chainDepth: Self.firstChainDepth, text: Self.text)
        #expect(try Self.inboxFile(messageID, of: session) == expected)
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an inbox file of a
    /// queued message that loses the source session or the header line.
    @Test("the inbox file of a queued user message keeps its source session and its header")
    func theInboxFileKeepsTheSourceSessionAndTheHeader() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        let source = await fixture.makeLiveRoot()
        let sourceSummary = try await fixture.liveDirectory.summary(of: source.id)
        let messageID = try await Self.sendMessage(to: session.id, from: source.id, in: fixture)

        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)

        let expected = SessionInboxMessage(
            id: messageID, from: Self.user, inReplyTo: nil, chainDepth: Self.firstChainDepth, text: Self.text,
            sourceSession: source.id, userHeader: UserMessageHeader(source: source.id, summary: sourceSummary).line)
        #expect(try Self.inboxFile(messageID, of: session) == expected)
        await source.close()
        await fixture.close(session)
    }

    /// The production change that makes this test fail: an archive that
    /// sends `messageDelivered` for the mail that it keeps.
    @Test("an archive sends no messageDelivered for a kept message")
    func anArchiveSendsNoDeliveryForAKeptMessage() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        _ = try await Self.sendMessage(to: session.id, in: fixture)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)
        fixture.liveDirectory.emit(Self.marker)

        #expect(!Self.holdsDelivery(await events.next(through: Self.marker)))
        await fixture.close(session)
    }

    /// The production change that makes this test fail: a kept message that
    /// the scan of the inbox removes with no delivery, because the ledger
    /// holds its id, or an archive that leaves the running turn going.
    @Test("archive, unarchive and open: the turn ended cancelled, and the queued message reaches the session")
    func theQueuedMessageReachesTheSessionWhenItOpens() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let (session, prompt) = try await fixture.startHeldTurn()
        let messageID = try await Self.sendMessage(to: session.id, in: fixture)
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)
        let unread = try await fixture.readingDirectory.inbox(of: session.id, markRead: false)

        let (launcher, opened, delivered) = try await Self.reopen(session.id, awaiting: messageID, in: fixture)

        let turnEnd = try await session.awaitTerminal(of: prompt)
        #expect(turnEnd == .answerFailed(AnswerFailure(mailIds: [prompt], reason: .cancelled)))
        #expect(unread.map(\.id) == [messageID])
        #expect(delivered?.text == Self.text)
        #expect(await opened.transcript.promptTexts.contains { $0.contains(Self.text) })
        await launcher.closeSessions()
        await fixture.close(session)
    }

    // MARK: - The inbox files

    /// The production change that makes this test fail: an archive that
    /// puts the files of the inbox in the queue and drops their mail, so the
    /// session finds no message when it opens.
    @Test("an inbox file that waits at the archive stays, and reaches the session when it opens")
    func anInboxFileStaysAndReachesTheSession() async throws {
        let fixture = try await RouterSessionDirectoryArchiveTests.makeFixture()
        let (session, _) = try await fixture.startHeldTurn()
        let file = SessionInboxMessage(
            id: MailID(), from: .session(ULID.generate()), inReplyTo: nil, chainDepth: Self.firstChainDepth,
            text: Self.text)
        try SessionInboxFile.write(
            file, to: session.recordingDirectory, maxMessageBytes: SessionMessageLimits().maxMessageBytes)
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)
        let kept = try Self.inboxFile(file.id, of: session)

        let (launcher, _, delivered) = try await Self.reopen(session.id, awaiting: file.id, in: fixture)

        #expect(kept == file)
        #expect(delivered?.text == Self.text)
        await launcher.closeSessions()
        await fixture.close(session)
    }

    // MARK: - The registry

    /// A message to a new session id that waits for its delivery, with no
    /// header.
    ///
    /// - Returns: The waiting message.
    private static func awaitedDelivery() -> RouterSessionDirectory.AwaitedDelivery {
        RouterSessionDirectory.AwaitedDelivery(
            message: SessionMessage(
                id: MailID(), from: user, to: ULID.generate(), text: text, sentAt: Date(),
                chainDepth: firstChainDepth),
            userHeader: nil)
    }

    /// The production change that makes this test fail: a fate that drops
    /// the message of a cancelled mail while its session archives.
    @Test("a mail that ends with no delivery while its session archives is kept")
    func aCancelledMailOfAnArchivingSessionIsKept() {
        var registry = RouterSessionDirectory.Registry()
        let awaited = Self.awaitedDelivery()
        registry.awaitingDelivery[awaited.message.id] = awaited
        registry.startKeepingMail(of: awaited.message.to)

        registry.apply(.cancelledOrLost(awaited.message.id))

        #expect(registry.takeKeptMail(of: awaited.message.to).map(\.message) == [awaited.message])
    }

    /// The production change that makes this test fail: a take of the kept
    /// mail that leaves out a message whose mail still waits, so a mail that
    /// the cancel did not reach is lost.
    @Test("a message that still waits for its delivery at the take is kept")
    func aWaitingMessageIsKeptAtTheTake() {
        var registry = RouterSessionDirectory.Registry()
        let awaited = Self.awaitedDelivery()
        registry.awaitingDelivery[awaited.message.id] = awaited
        registry.startKeepingMail(of: awaited.message.to)

        let kept = registry.takeKeptMail(of: awaited.message.to)

        #expect(kept.map(\.message) == [awaited.message])
    }

    // MARK: - Memory only

    /// The production change that makes this test fail: an archive of a
    /// memory-only session that delivers its waiting mail, or that sends
    /// `messageDelivered` for it.
    @Test("the waiting mail of a memory-only session ends cancelled, with no messageDelivered")
    func theWaitingMailOfAMemoryOnlySessionEndsCancelled() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryArchiveMailTests-memory")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let latch = RunLatch()
        let backend = RouterSessionDirectoryArchiveTests.Backend(script: [1: .hold(latch)])
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: scratch)
        let session = profile.standard.makeSession(configuration: SessionConfiguration())
        _ = try session.send("first question")
        try await backend.changes.wait(untilAtLeast: 1) { backend.prompts.count }
        let receipts = try await router.sessionDirectory.send(
            OutgoingSessionMessage(from: Self.user, to: .session(session.id), text: Self.text))
        let waiting = try #require(receipts.first?.messageID)
        var events = router.sessionDirectory.events().makeAsyncIterator()

        _ = try await router.sessionDirectory.archive(session.id, by: Self.user)
        router.sessionDirectory.emit(Self.marker)

        #expect(!Self.holdsDelivery(await events.next(through: Self.marker)))
        #expect(try await session.awaitTerminal(of: waiting) == .cancelled(waiting))
        await latch.open()
        await session.close()
    }
}
