import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The messages between sessions of ``RouterSessionDirectory`` (ROUTER-4):
/// `send(_:)` resolves the address, delivers a `Mail` to each live target,
/// keeps a `SessionMessage` in the ledger of the target (`messages.jsonl`),
/// and sends `messageDelivered`; `inbox(of:markRead:)` and `message(_:to:)`
/// read the ledger.
///
/// Each test runs on a router that records to a durable root, with a
/// ``FakeSessionLauncher`` over its scripted profile. A delivered message
/// starts a turn that the scripted model answers.
@Suite struct RouterSessionDirectoryMessageTests {
    /// A router over a durable recordings root, and a launcher over its
    /// profile.
    struct Fixture {
        /// The cache and recordings folders of the test.
        let directories: TestDirectories

        /// The router whose directory is under test.
        let router: Router

        /// The resolved profile of ``router``.
        let profile: LanguageModelProfile

        /// The launcher of the directory.
        let launcher: FakeSessionLauncher

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends a root session of ``router``. The caller holds it.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The session, live in ``directory``.
        func makeSession(_ configuration: SessionConfiguration = SessionConfiguration()) -> any RoutedSession {
            profile.standard.makeSession(configuration: configuration)
        }

        /// The folder that holds the recording directory of each root
        /// session of ``router``.
        ///
        /// - Parameter session: A root session of ``router``.
        /// - Returns: The recording root of `session`.
        func recordingRoot(of session: any RoutedSession) -> URL {
            session.recordingDirectory.deletingLastPathComponent()
        }

        /// Closes `sessions` and each session of ``launcher``, so each record
        /// of them is on disk.
        ///
        /// - Parameter sessions: The sessions the test vended.
        func closeSessions(_ sessions: [any RoutedSession]) async {
            for session in sessions {
                await session.close()
            }
            await launcher.closeSessions()
        }

        /// Closes `sessions` and each session of ``launcher``, and removes the
        /// folders of the test.
        ///
        /// - Parameter sessions: The sessions the test vended.
        func close(_ sessions: [any RoutedSession]) async {
            await closeSessions(sessions)
            directories.remove()
        }
    }

    /// Makes a fixture whose directory uses a launcher over its profile.
    ///
    /// - Returns: The fixture.
    private static func makeFixture() async throws -> Fixture {
        let directories = TestDirectories(prefix: "RouterSessionDirectoryMessageTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let launcher = FakeSessionLauncher(profile: profile)
        await router.sessionDirectory.use(launcher: launcher)
        return Fixture(directories: directories, router: router, profile: profile, launcher: launcher)
    }

    /// The mail that the transcript of `session` recorded as queued with the
    /// id `id`. Call it after the session closed, so each record is on disk.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - session: A closed root session of `fixture`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The queued mail.
    private static func queuedMail(
        _ id: MailID, of session: any RoutedSession, in fixture: Fixture
    ) throws -> Mail {
        let tree = try TranscriptTree.load(under: fixture.recordingRoot(of: session))
        let queued = try tree.events(forSession: session.id).flatMap(\.mailRecords).compactMap { record -> Mail? in
            guard case .mailQueued(let mail) = record, mail.id == id else { return nil }
            return mail
        }
        return try #require(queued.first)
    }

    /// The id of the message of the one receipt of a send.
    ///
    /// - Parameter receipts: The receipts of a send.
    /// - Returns: The message id of the first receipt.
    private static func messageID(of receipts: [SessionSendReceipt]) throws -> MailID {
        try #require(receipts.first?.messageID)
    }

    // MARK: - A session sender

    /// A message from session A to session B by id goes into the mail queue
    /// of B: the transcript of B holds the mail with the sender A, the
    /// receipt is `delivered`, and one `messageDelivered` follows.
    @Test func aMessageBySessionIdReachesTheTargetAndItsTranscript() async throws {
        let fixture = try await Self.makeFixture()
        let sender = fixture.makeSession()
        let target = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .session(target.id), text: Self.text))
        fixture.directory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        let messageID = try Self.messageID(of: receipts)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        let delivered = try #require(try await fixture.directory.message(messageID, to: target.id))
        #expect(received == [.messageDelivered(delivered), Self.marker])
        #expect(delivered.from == .session(sender.id))
        #expect(delivered.text == Self.text)
        #expect(delivered.chainDepth == 1)
        #expect(await target.awaitIdle())
        let senderSummary = try #require(try await fixture.directory.summary(of: sender.id))
        await fixture.closeSessions([sender, target])
        let mail = try Self.queuedMail(messageID, of: target, in: fixture)
        let header = AgentMessageHeader(
            sender: sender.id, agentID: senderSummary.agentID, agentName: nil, title: nil,
            folder: senderSummary.workingDirectory.path, inReplyTo: nil)
        let content = AgentMessageContent(header: header, text: Self.text).encoded
        #expect(mail == Mail(id: messageID, sender: .session(sender.id), body: .agentMessage(from: sender.id, content: content)))
        await fixture.close([])
    }

    /// The mail of a message from a session starts with the header that the
    /// directory writes from the live summary of the sender: its agent,
    /// title and folder, and the message that the message answers. The text
    /// of the sender follows the header.
    @Test func theMailOfAMessageCarriesTheHeaderOfTheSender() async throws {
        let fixture = try await Self.makeFixture()
        let folder = fixture.directories.cacheDir
        let sender = fixture.makeSession(SessionConfiguration(workingDirectory: folder, agentID: Self.agentID, title: Self.title))
        let target = fixture.makeSession()
        let answered = MailID()

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .session(target.id), text: Self.text, inReplyTo: answered))

        let messageID = try Self.messageID(of: receipts)
        #expect(await target.awaitIdle())
        await fixture.closeSessions([sender, target])
        let mail = try Self.queuedMail(messageID, of: target, in: fixture)
        let header = AgentMessageHeader(
            sender: sender.id, agentID: Self.agentID, agentName: nil, title: Self.title, folder: folder.path,
            inReplyTo: answered)
        #expect(mail.body == .agentMessage(from: sender.id, content: AgentMessageContent(header: header, text: Self.text).encoded))
        await fixture.close([])
    }

    // MARK: - A UI sender

    /// A message from a UI goes as a user message with the sender `user`, and
    /// the record keeps the client id of the UI.
    @Test func aMessageFromAUIIsAUserMessageAndTheRecordKeepsTheClient() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(target.id), text: Self.text))

        let messageID = try Self.messageID(of: receipts)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        let delivered = try #require(try await fixture.directory.message(messageID, to: target.id))
        #expect(delivered.from == .user(clientID: Self.clientID))
        #expect(await target.awaitIdle())
        await fixture.closeSessions([target])
        let mail = try Self.queuedMail(messageID, of: target, in: fixture)
        #expect(mail == Mail(id: messageID, sender: .user, body: .userMessage(prompt: Self.text, options: UserMessageOptions())))
        await fixture.close([])
    }

    // MARK: - The ledger after a restore

    /// The sender, `inReplyTo`, the chain depth and the client id of a UI
    /// sender read back from the inbox of the target after a new router
    /// restores it.
    @Test func theRecordReadsBackAfterTheTargetIsRestored() async throws {
        let fixture = try await Self.makeFixture()
        let sender = fixture.makeSession()
        let target = fixture.makeSession()
        let answered = MailID()
        let fromSession = try await fixture.directory.send(
            OutgoingSessionMessage(
                from: .session(sender.id), to: .session(target.id), text: Self.text, inReplyTo: answered))
        let fromUI = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(target.id), text: Self.text))
        let sentFromSession = try await fixture.directory.message(try Self.messageID(of: fromSession), to: target.id)
        let sentFromUI = try await fixture.directory.message(try Self.messageID(of: fromUI), to: target.id)
        let sent = [try #require(sentFromSession), try #require(sentFromUI)]
        #expect(await target.awaitIdle())
        await fixture.closeSessions([sender, target])
        let (inbox, restored) = try await Self.inboxAfterARestore(of: target.id, in: fixture)

        #expect(inbox == sent)
        #expect(inbox.first?.inReplyTo == answered)
        #expect(inbox.last?.from == .user(clientID: Self.clientID))
        #expect(inbox.map(\.chainDepth) == [1, 1])
        await restored.close()
        await fixture.close([])
    }

    /// The production change that makes this test fail: a `sentAt` stamped
    /// at the start of its whole second, which reads back earlier than the
    /// send.
    @Test func theSentAtOfAMessageReadsBackAfterARestoreToTheMillisecond() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let sendStart = DateTime(Date())
        _ = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(target.id), text: Self.text))
        let sendEnd = DateTime(Date())
        #expect(await target.awaitIdle())
        await fixture.closeSessions([target])

        let (inbox, restored) = try await Self.inboxAfterARestore(of: target.id, in: fixture)

        let sentAt = DateTime(try #require(inbox.first).sentAt)
        #expect(sendStart <= sentAt)
        #expect(sentAt <= sendEnd)
        await restored.close()
        await fixture.close([])
    }

    /// Restores a closed session of `fixture` on a new router over the same
    /// recordings, as a host does after a restart, and reads its inbox there.
    ///
    /// - Parameters:
    ///   - id: The id of a closed root session of `fixture`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The inbox of the restored session, every message with no
    ///   read mark, and the restored session. The caller closes it.
    private static func inboxAfterARestore(
        of id: ULID, in fixture: Fixture
    ) async throws -> (inbox: [SessionMessage], restored: any RoutedSession) {
        let recorder = await fixture.router.recorder
        let resumingRouter = RouterTestFixtures.makeRouter(
            id: fixture.router.id, cacheDir: fixture.directories.cacheDir,
            recordingsDir: fixture.directories.recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension))
        let resumingProfile = try await resumingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await resumingProfile.standard.restoreSession(id: id)
        let inbox = try await resumingRouter.sessionDirectory.inbox(of: id, markRead: false)
        return (inbox, restored.session)
    }

    /// The inbox of a recorded session that is not live reads its ledger
    /// from its folder under the recording roots of the host.
    @Test func theInboxOfARecordedSessionReadsItsFolder() async throws {
        let fixture = try await Self.makeFixture()
        var target: (any RoutedSession)? = fixture.makeSession()
        let id = try #require(target?.id)
        let root = try #require(target.map(fixture.recordingRoot(of:)))
        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(id), text: Self.text))
        #expect(await target?.awaitIdle() == true)
        await target?.close()
        target = nil
        await fixture.directory.useRecordingRoots { [root] }

        let inbox = try await fixture.directory.inbox(of: id, markRead: false)

        #expect(inbox.map(\.id) == [try Self.messageID(of: receipts)])
        await fixture.close([])
    }

    // MARK: - The decisions of the resolver

    /// An agent address with a live root session of the agent delivers to it.
    @Test func anAgentWithALiveRootDeliversToIt() async throws {
        let fixture = try await Self.makeFixture()
        let folder = fixture.directories.cacheDir
        let target = fixture.makeSession(SessionConfiguration(workingDirectory: folder, agentID: Self.agentID))

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(
                from: .user(clientID: Self.clientID), to: .agent(id: Self.agentID, folder: folder), text: Self.text))

        let messageID = try Self.messageID(of: receipts)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        #expect(fixture.launcher.requests.isEmpty)
        await fixture.close([target])
    }

    /// An agent address with no live session starts one through the
    /// launcher, with origin `message`, the folder and the id of the sender,
    /// and the message as its first message; the receipt is `started`.
    @Test func anAgentWithNoLiveSessionStartsOne() async throws {
        let fixture = try await Self.makeFixture()
        let sender = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .agent(id: Self.agentID, folder: nil), text: Self.text))
        fixture.directory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        let started = try #require(fixture.launcher.sessions.first)
        let messageID = try Self.messageID(of: receipts)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: started.id, outcome: .started)])
        #expect(
            fixture.launcher.requests == [
                SessionStartRequest(
                    agentID: Self.agentID, workingDirectory: sender.workingDirectory, firstMessage: Self.text,
                    startedBy: sender.id, origin: .message)
            ])
        let delivered = try #require(try await fixture.directory.message(messageID, to: started.id))
        #expect(delivered.from == .session(sender.id))
        #expect(received.last(where: { $0 != Self.marker }) == .messageDelivered(delivered))
        await fixture.close([sender])
    }

    /// An agent address that must start a session throws `noLauncher` from a
    /// directory with no launcher.
    @Test func anAgentStartWithNoLauncherThrowsNoLauncher() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.directory.shutdown()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await fixture.directory.send(
                OutgoingSessionMessage(
                    from: .user(clientID: Self.clientID), to: .agent(id: Self.agentID, folder: nil), text: Self.text))
        }
        await fixture.close([])
    }

    /// A folder address with a live root session in the folder delivers to
    /// it.
    @Test func aFolderWithALiveRootDeliversToIt() async throws {
        let fixture = try await Self.makeFixture()
        let folder = fixture.directories.cacheDir
        let target = fixture.makeSession(SessionConfiguration(workingDirectory: folder))

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .folder(folder), text: Self.text))

        let messageID = try Self.messageID(of: receipts)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        await fixture.close([target])
    }

    /// A folder address with no live root session is refused with the hint
    /// to name an agent, and no target.
    @Test func aFolderWithNoLiveRootIsRefusedWithTheHint() async throws {
        let fixture = try await Self.makeFixture()

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(
                from: .user(clientID: Self.clientID), to: .folder(fixture.directories.cacheDir), text: Self.text))

        #expect(
            receipts == [
                SessionSendReceipt(outcome: .refused, reason: SessionAddressResolution.noRootSessionInTheFolderReason)
            ])
        await fixture.close([])
    }

    /// A tag address delivers to each live session with the tag but the
    /// sender, the oldest first.
    @Test func aTagDeliversToEachSessionWithTheTagButTheSender() async throws {
        let fixture = try await Self.makeFixture()
        let tagged = SessionConfiguration(tags: [Self.tag])
        let sender = fixture.makeSession(tagged)
        let first = fixture.makeSession(tagged)
        let second = fixture.makeSession(tagged)

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .tag(Self.tag), text: Self.text))

        #expect(receipts.map(\.target) == [first.id, second.id])
        #expect(receipts.allSatisfy { $0.outcome == .delivered && $0.messageID != nil })
        await fixture.close([sender, first, second])
    }

    /// A tag address that no live session but the sender has gives one
    /// `refused` receipt with no target.
    @Test func aTagThatNoOtherSessionHasIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        let sender = fixture.makeSession(SessionConfiguration(tags: [Self.tag]))

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .session(sender.id), to: .tag(Self.tag), text: Self.text))

        #expect(
            receipts == [SessionSendReceipt(outcome: .refused, reason: SessionAddressResolution.noSessionHasTheTagReason)]
        )
        await fixture.close([sender])
    }

    /// A session id that no live or recorded session has throws
    /// `unknownSession`.
    @Test func anUnknownSessionIdThrows() async throws {
        let fixture = try await Self.makeFixture()
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.directory.send(
                OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(unknown), text: Self.text))
        }
        await fixture.close([])
    }

    // MARK: - The inbox

    /// The inbox gives the messages that are not read; with `markRead` a
    /// second call gives none.
    @Test func theInboxWithMarkReadGivesTheUnreadMessagesOnce() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let sent = try await Self.sendTwo(to: target, in: fixture)

        let first = try await fixture.directory.inbox(of: target.id, markRead: true)
        let second = try await fixture.directory.inbox(of: target.id, markRead: true)

        #expect(first.map(\.id) == sent)
        #expect(first.allSatisfy { !$0.isRead })
        #expect(second.isEmpty)
        await fixture.close([target])
    }

    /// The inbox with no `markRead` leaves the messages unread.
    @Test func theInboxWithNoMarkReadLeavesTheMessagesUnread() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let sent = try await Self.sendTwo(to: target, in: fixture)

        _ = try await fixture.directory.inbox(of: target.id, markRead: false)
        let again = try await fixture.directory.inbox(of: target.id, markRead: false)

        #expect(again.map(\.id) == sent)
        await fixture.close([target])
    }

    /// The inbox of a memory-only session lives in memory.
    @Test func theInboxOfAMemoryOnlySessionWorks() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryMessageTests-memory")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch)
        let target = profile.standard.makeSession(configuration: SessionConfiguration())
        let receipts = try await router.sessionDirectory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(target.id), text: Self.text))

        let inbox = try await router.sessionDirectory.inbox(of: target.id, markRead: false)

        #expect(inbox.map(\.id) == [try Self.messageID(of: receipts)])
        let ledgerFile = target.recordingDirectory.appendingPathComponent(SessionMessageLedger.fileName)
        #expect(!FileManager.default.fileExists(atPath: ledgerFile.path))
        await target.close()
        withExtendedLifetime(router) {}
    }

    /// The inbox of an id that no session has throws `unknownSession`.
    @Test func theInboxOfAnUnknownSessionThrows() async throws {
        let fixture = try await Self.makeFixture()
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.directory.inbox(of: unknown, markRead: false)
        }
        await fixture.close([])
    }

    // MARK: - The lookup of one message

    /// A lookup finds a message that was read, with its read flag.
    @Test func aLookupFindsAReadMessage() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let sent = try await Self.sendTwo(to: target, in: fixture)
        _ = try await fixture.directory.inbox(of: target.id, markRead: true)

        let found = try await fixture.directory.message(sent[0], to: target.id)

        #expect(found?.isRead == true)
        await fixture.close([target])
    }

    /// A lookup marks nothing read: the message stays in the inbox.
    @Test func aLookupMarksNothingRead() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let sent = try await Self.sendTwo(to: target, in: fixture)

        let found = try await fixture.directory.message(sent[0], to: target.id)

        #expect(found?.isRead == false)
        let inbox = try await fixture.directory.inbox(of: target.id, markRead: false)
        #expect(inbox.map(\.id) == sent)
        await fixture.close([target])
    }

    /// A lookup gives `nil` for an unknown id, for a message that went to
    /// another session, and for a recipient that names no session, and it
    /// throws for none of them.
    @Test func aLookupGivesNilForEachMiss() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let other = fixture.makeSession()
        let sent = try await Self.sendTwo(to: target, in: fixture)

        let unknownID = try await fixture.directory.message(MailID(), to: target.id)
        let otherRecipient = try await fixture.directory.message(sent[0], to: other.id)
        let noSession = try await fixture.directory.message(sent[0], to: ULID.generate())

        #expect(unknownID == nil)
        #expect(otherRecipient == nil)
        #expect(noSession == nil)
        await fixture.close([target, other])
    }

    /// Sends two UI messages to `target`.
    ///
    /// - Parameters:
    ///   - target: A live session of `fixture`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The ids of the two messages, in the order they were sent.
    private static func sendTwo(to target: any RoutedSession, in fixture: Fixture) async throws -> [MailID] {
        let first = try await send("first", to: target, in: fixture)
        let second = try await send("second", to: target, in: fixture)
        return [first, second]
    }

    /// Sends one UI message to `target`.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - target: A live session of `fixture`.
    ///   - fixture: The fixture of the test.
    /// - Returns: The id of the message.
    private static func send(_ text: String, to target: any RoutedSession, in fixture: Fixture) async throws -> MailID {
        try messageID(
            of: try await fixture.directory.send(
                OutgoingSessionMessage(from: .user(clientID: clientID), to: .session(target.id), text: text)))
    }

    // MARK: - Constants

    /// An event no test session sends, which a test sends to mark the end of
    /// what it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The UI client that sends each UI message.
    private static let clientID = "client-a"

    /// The agent of each agent address.
    private static let agentID = "reviewer"

    /// The title of a sender whose header a test reads.
    private static let title = "Review"

    /// The tag of each tag address.
    private static let tag = "triage"
}
