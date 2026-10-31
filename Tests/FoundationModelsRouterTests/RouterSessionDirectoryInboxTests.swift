import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The scan of the `inbox/` folder of a live durable session
/// (``RouterSessionDirectory/scanInbox(of:)``): a file there is a message
/// that goes through the same delivery as a send. The file is removed after
/// the delivery, a file whose id the ledger holds is removed with no second
/// delivery, a file that does not parse moves to `inbox/rejected/`, and a
/// refusal or a ledger read error leaves the file where it is.
///
/// The registration of a durable session also starts the watcher of its
/// inbox folder (``SessionInboxWatcher``). A file that arrives is delivered
/// with no call to the scan, and the close and the archive of the session
/// stop the watcher. A test waits for the `messageDelivered` event, never
/// for the clock.
///
/// Each test uses the fixture of ``RouterSessionDirectoryDeliveryTests``,
/// and the loop guard test uses the fixture of ``SessionMessageLoopGuardTests``.
@Suite("RouterSessionDirectory: the scan of the inbox folder of a session")
struct RouterSessionDirectoryInboxTests {
    // MARK: - Constants

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The chain depth of a file that a hand wrote after a chain of two
    /// messages.
    private static let fileChainDepth = 3

    /// The chain depth of the file in the loop guard test: one below the
    /// deepest chain, so the next send of the turn is the last one allowed.
    private static let chainDepthBelowTheLimit = 2

    /// The text of a file that has no frontmatter.
    private static let fileWithoutFrontmatter = "Only text, and no header.\n"

    /// A key that the format of the file does not know.
    private static let unknownKey = "priority"

    /// The value of ``unknownKey``.
    private static let unknownValue = "high"

    /// The name of a file that sorts after every file named by an id (a
    /// lower case letter sorts after the upper case letters and digits of
    /// an id).
    private static let laterFileName = "z-later.md"

    /// The scans that run at the same time in the test of two scans.
    private static let scansOfOneFile = 2

    /// The number of the first call of a scripted backend: the call that
    /// the held turn makes.
    private static let firstCall = 1

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The names of the files that the scan of the inbox skips: a temporary
    /// file of a writer, a dot file and a file that is not markdown.
    private static let ignoredNames = [".\(ULID()).md.tmp", ".hidden.md", "notes.txt"]

    /// The error of a launcher whose restore fails.
    private struct RestoreFailure: Error, CustomStringConvertible {
        /// The text of the error.
        var description: String { "the host cannot restore the session" }
    }

    // MARK: - Helpers

    /// Writes one message file to the inbox of `session`, as a process that
    /// does not own the session does.
    ///
    /// - Parameters:
    ///   - session: The target session.
    ///   - id: The id of the message. The default is a new id.
    ///   - chainDepth: The chain depth of the message.
    ///   - unknownKeys: The frontmatter keys that the format does not know.
    /// - Returns: The id of the message.
    /// - Throws: The error of the write.
    @discardableResult
    private static func writeFile(
        to session: any RoutedSession, id: MailID = MailID(), chainDepth: Int = 1,
        unknownKeys: [String: JSONValue] = [:]
    ) throws -> MailID {
        let message = SessionInboxMessage(
            id: id, from: .user(clientID: clientID), inReplyTo: nil, chainDepth: chainDepth, text: text,
            unknownKeys: unknownKeys)
        try SessionInboxFile.write(
            message, to: session.recordingDirectory, maxMessageBytes: SessionMessageLimits().maxMessageBytes)
        return id
    }

    /// The files that wait in the inbox of `session`.
    ///
    /// - Parameter session: A durable session.
    /// - Returns: The file names, in order.
    /// - Throws: The error of the folder read.
    private static func waitingNames(of session: any RoutedSession) throws -> [String] {
        try SessionInboxFile.pending(in: session.recordingDirectory).map(\.lastPathComponent)
    }

    /// The names of the files in `inbox/rejected/` of `session`.
    ///
    /// - Parameter session: A durable session.
    /// - Returns: The file names, in order. Empty when the folder is absent.
    private static func rejectedNames(of session: any RoutedSession) -> [String] {
        let folder = SessionInboxFile.rejectedDirectory(in: session.recordingDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - Delivery

    /// The production change that makes this test fail: a scan that does
    /// not put the mail in the queue of an idle session, that keeps no
    /// message in the ledger, or that leaves the file in the inbox.
    @Test("a file in the inbox of an idle session starts a turn, the ledger holds the message, and the file is gone")
    func aFileForAnIdleSessionStartsATurn() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target, chainDepth: Self.fileChainDepth)

        await fixture.directory.scanInbox(of: target.id)

        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        let kept = try #require(try await fixture.directory.message(id, to: target.id))
        #expect(kept.chainDepth == Self.fileChainDepth)
        #expect(kept.from == .user(clientID: Self.clientID))
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a scan that starts
    /// a turn for a working session, or that drops the message.
    @Test("a file for a working session waits in the mail queue until the turn ends")
    func aFileForAWorkingSessionWaitsInTheQueue() async throws {
        let latch = RunLatch()
        let backend = RouterSessionDirectoryDeliveryTests.Backend(script: [Self.firstCall: .hold(latch)])
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let target = try await RouterSessionDirectoryDeliveryTests.startHeldTurn(in: fixture, on: backend)
        let id = try Self.writeFile(to: target)

        await fixture.directory.scanInbox(of: target.id)
        let waiting = await RouterSessionDirectoryDeliveryTests.pendingIDs(of: target)
        let promptsDuringTheTurn = backend.prompts.count
        await latch.open()

        #expect(waiting == [id])
        #expect(promptsDuringTheTurn == Self.firstCall)
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts.last == Self.text)
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a scan that does not
    /// read the keys of the file it does not know, or that stops on them.
    @Test("a file with an unknown frontmatter key is delivered")
    func aFileWithAnUnknownKeyIsDelivered() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target, unknownKeys: [Self.unknownKey: .string(Self.unknownValue)])

        await fixture.directory.scanInbox(of: target.id)

        #expect(await target.awaitIdle())
        #expect(try await fixture.directory.message(id, to: target.id) != nil)
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    // MARK: - Idempotence

    /// The production change that makes this test fail: a scan that
    /// delivers a file whose id the ledger holds, as after a crash between
    /// the delivery and the removal of the file.
    @Test("a file whose id the ledger holds is removed, and is not delivered again")
    func aFileOfADeliveredMessageIsRemovedOnly() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target)
        await fixture.directory.scanInbox(of: target.id)
        #expect(await target.awaitIdle())
        try Self.writeFile(to: target, id: id)

        await fixture.directory.scanInbox(of: target.id)

        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        #expect(try await fixture.directory.inbox(of: target.id, markRead: false).map(\.id) == [id])
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a scan with a
    /// suspension point between the check of the ledger and the record, so
    /// two scans both deliver the file.
    @Test("two scans at the same time deliver one file one time")
    func twoScansDeliverOneFileOnce() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target)
        let directory = fixture.directory
        let targetID = target.id

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.scansOfOneFile {
                group.addTask { await directory.scanInbox(of: targetID) }
            }
        }

        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        #expect(try await fixture.directory.inbox(of: target.id, markRead: false).map(\.id) == [id])
        await fixture.close([target])
    }

    // MARK: - Files that stay or move

    /// The production change that makes this test fail: a scan that deletes
    /// a file that does not parse, or that leaves it in the inbox.
    @Test("a file that does not parse moves to inbox/rejected, and the files after it are delivered")
    func aFileThatDoesNotParseIsRejected() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let badName = "\(ULID()).md"
        let inbox = SessionInboxFile.directory(in: target.recordingDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Self.fileWithoutFrontmatter.write(
            to: inbox.appendingPathComponent(badName), atomically: true, encoding: .utf8)
        let id = try Self.writeFile(to: target)

        await fixture.directory.scanInbox(of: target.id)

        #expect(Self.rejectedNames(of: target) == [badName])
        #expect(try Self.waitingNames(of: target).isEmpty)
        #expect(await target.awaitIdle())
        #expect(try await fixture.directory.message(id, to: target.id) != nil)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a scan that does
    /// not return at the guard for a session that is not live (the close of
    /// a session takes it off the live list), and that removes the file of
    /// that session.
    @Test("a session that is not live leaves the file in the inbox")
    func aSessionThatIsNotLiveLeavesTheFile() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target)
        await target.close()

        await fixture.directory.scanInbox(of: target.id)

        #expect(try Self.waitingNames(of: target) == ["\(id).md"])
        #expect(Self.rejectedNames(of: target).isEmpty)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a scan that removes
    /// the file of a message that a refusal of the mail kept out of the
    /// ledger, that goes on to the next file after the refusal, or that
    /// records the message.
    ///
    /// The session is closed and then put on the live list again, so it is
    /// live for the scan and its mail refuses with ``MailRefusal/closed``.
    /// The second file does not parse: a scan that reads it moves it to
    /// `inbox/rejected/`.
    @Test("a refusal of the mail leaves the file in the inbox, the ledger empty, and the scan stops")
    func aRefusalOfTheMailLeavesTheFileAndStopsTheScan() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target)
        let laterName = Self.laterFileName
        let inbox = SessionInboxFile.directory(in: target.recordingDirectory)
        try Self.fileWithoutFrontmatter.write(
            to: inbox.appendingPathComponent(laterName), atomically: true, encoding: .utf8)
        await target.close()
        fixture.directory.register(target, kind: .root, parentID: nil)

        await fixture.directory.scanInbox(of: target.id)

        #expect(try Self.waitingNames(of: target) == ["\(id).md", laterName])
        #expect(Self.rejectedNames(of: target).isEmpty)
        #expect(try await fixture.directory.message(id, to: target.id) == nil)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a scan that treats
    /// a ledger it cannot read as an empty ledger, and delivers the file, or
    /// removes the file.
    @Test("a ledger that does not read leaves the file in the inbox, with no delivery")
    func aLedgerReadErrorLeavesTheFile() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        let id = try Self.writeFile(to: target)
        // A folder where the file of the ledger belongs: it exists, and it does not read.
        try FileManager.default.createDirectory(
            at: target.recordingDirectory.appendingPathComponent(SessionMessageLedger.fileName),
            withIntermediateDirectories: true)

        await fixture.directory.scanInbox(of: target.id)

        #expect(try Self.waitingNames(of: target) == ["\(id).md"])
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts.isEmpty)
        await fixture.close([target])
    }

    // MARK: - Chain depth

    /// The production change that makes this test fail: a scan that gives
    /// the message the first chain depth, so the loop guard does not see the
    /// chain that a file carries.
    @Test("the chain depth of a file reaches the ledger, and the next send of the turn gets one more")
    func theChainDepthOfAFileReachesTheNextSend() async throws {
        let fixture = try await SessionMessageLoopGuardTests.makeFixture()
        let sender = fixture.makeSession()
        let receiver = fixture.makeSession()
        fixture.tool.route(from: sender.id, to: .session(receiver.id))
        try Self.writeFile(to: sender, chainDepth: Self.chainDepthBelowTheLimit)

        await fixture.directory.scanInbox(of: sender.id)

        #expect(await sender.awaitIdle())
        #expect(fixture.tool.receipts(of: sender.id).flatMap { $0.map(\.outcome) } == [.delivered])
        #expect(
            try await fixture.directory.inbox(of: receiver.id, markRead: false).map(\.chainDepth)
                == [Self.chainDepthBelowTheLimit + 1])
        await fixture.close([sender, receiver])
    }

    /// The production change that makes this test fail: a scan that drops
    /// the chain depth of the file, so a chain of files has no end.
    @Test("a file at the deepest chain starts a turn whose next send is refused by the loop guard")
    func aFileAtTheDeepestChainIsRefusedOnTheNextSend() async throws {
        let fixture = try await SessionMessageLoopGuardTests.makeFixture()
        let sender = fixture.makeSession()
        let receiver = fixture.makeSession()
        fixture.tool.route(from: sender.id, to: .session(receiver.id))
        try Self.writeFile(to: sender, chainDepth: SessionMessageLimits().maxChainDepth)

        await fixture.directory.scanInbox(of: sender.id)

        #expect(await sender.awaitIdle())
        #expect(
            fixture.tool.receipts(of: sender.id)
                == [[SessionSendReceipt(outcome: .refused, reason: SessionMessageLimits().chainTooDeepReason)]])
        #expect(try await fixture.directory.inbox(of: receiver.id, markRead: false).isEmpty)
        await fixture.close([sender, receiver])
    }

    // MARK: - Send

    /// A launcher that reads the `inbox/` folder of a recorded session at the
    /// start of each restore, and then restores through a ``FakeSessionLauncher``.
    /// It shows which files wait in the inbox when the restore runs.
    private final class RestoreWitness: SessionLauncher {
        /// The launcher that does the restore.
        private let inner: FakeSessionLauncher

        /// The session folder whose inbox the witness reads.
        private let folder: URL

        /// The names of the files in the inbox at the start of the last
        /// restore.
        private let names = Mutex<[String]>([])

        /// Makes a witness of the inbox in `folder`.
        ///
        /// - Parameters:
        ///   - inner: The launcher that does the restore.
        ///   - folder: The session folder of the recorded session.
        init(inner: FakeSessionLauncher, folder: URL) {
            self.inner = inner
            self.folder = folder
        }

        /// The names of the files in the inbox at the start of the last
        /// restore.
        var namesAtRestore: [String] {
            names.withLock { $0 }
        }

        /// Starts a root session through the inner launcher.
        func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
            try await inner.launchRootSession(for: request)
        }

        /// Reads the inbox, and then restores the session `id` through the
        /// inner launcher.
        func restoreSession(id: ULID) async throws -> any RoutedSession {
            let pending = try SessionInboxFile.pending(in: folder).map(\.lastPathComponent)
            names.withLock { $0 = pending }
            return try await inner.restoreSession(id: id)
        }
    }

    /// Sends one UI message to the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session id of the target.
    ///   - directory: The directory that sends.
    /// - Returns: The receipts of the send.
    /// - Throws: The error of the send.
    private static func send(
        to id: ULID, through directory: RouterSessionDirectory
    ) async throws -> [SessionSendReceipt] {
        try await directory.send(
            OutgoingSessionMessage(from: .user(clientID: clientID), to: .session(id), text: text))
    }

    /// Records a closed durable session in the fixture, and gives the
    /// directory its recording root.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The id and the session folder of the recorded session.
    /// - Throws: The `#require` failure when the vended session is not a
    ///   ``RoutedSessionActor``.
    private static func recordClosedSession(
        in fixture: RouterSessionDirectoryDeliveryTests.Fixture
    ) async throws -> (id: ULID, folder: URL) {
        let recorded = try #require(fixture.makeSession() as? RoutedSessionActor)
        await recorded.close()
        await fixture.directory.useRecordingRoots { [recorded.recordingDirectory.deletingLastPathComponent()] }
        return (recorded.id, recorded.recordingDirectory)
    }

    /// The production change that makes this test fail: a send that does not
    /// carry the UI client id through the file, or that leaves the file in
    /// the inbox after the delivery.
    @Test("a send to a live durable session is delivered from a file, and the client id and the chain depth survive")
    func aSendToALiveDurableSessionGoesThroughAFile() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let target = fixture.makeSession()

        let receipts = try await Self.send(to: target.id, through: fixture.directory)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        #expect(await Self.awaitDelivery(of: messageID, reading: &events))
        let kept = try #require(try await fixture.directory.message(messageID, to: target.id))
        #expect(kept.from == .user(clientID: Self.clientID))
        #expect(kept.chainDepth == RouterSessionDirectory.firstChainDepth)
        #expect(try await fixture.directory.inbox(of: target.id, markRead: false).map(\.from) == [kept.from])
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a send to a durable
    /// session that puts the mail in the queue and the message in the ledger
    /// itself, so no file waits, and the receipt of a closing session is
    /// `refused`.
    @Test("a send to a session that is closing but registered gives delivered, and the file waits for the next open")
    func aClosingSessionGetsAFileThatWaits() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        await target.close()
        fixture.directory.register(target, kind: .root, parentID: nil)

        let receipts = try await Self.send(to: target.id, through: fixture.directory)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        let file = SessionInboxFile.url(of: messageID, in: target.recordingDirectory)
        let waiting = try SessionInboxFile.read(file, maxMessageBytes: SessionMessageLimits().maxMessageBytes)
        #expect(waiting.from == .user(clientID: Self.clientID))
        #expect(waiting.text == Self.text)
        #expect(waiting.chainDepth == RouterSessionDirectory.firstChainDepth)
        #expect(try await fixture.directory.message(messageID, to: target.id) == nil)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a send that writes
    /// the message to the ledger before it returns, so no delivery event
    /// follows the receipt.
    @Test("the message id of the receipt is in the ledger after the delivery event")
    func theLedgerHoldsTheMessageAfterTheDeliveryEvent() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let target = fixture.makeSession()

        let receipts = try await Self.send(to: target.id, through: fixture.directory)

        let messageID = try #require(receipts.first?.messageID)
        #expect(await Self.awaitDelivery(of: messageID, reading: &events))
        #expect(try await fixture.directory.message(messageID, to: target.id)?.text == Self.text)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a send to a
    /// memory-only session that writes a file, or that does not call the
    /// mail of the session itself.
    @Test("a send to a memory-only session puts the mail in the queue itself and writes no file")
    func aMemoryOnlySessionGetsTheMailDirectly() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryInboxTests-send")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch)
        let target = profile.standard.makeSession(configuration: SessionConfiguration())

        let receipts = try await Self.send(to: target.id, through: router.sessionDirectory)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        #expect(try await router.sessionDirectory.message(messageID, to: target.id)?.text == Self.text)
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        let inbox = SessionInboxFile.directory(in: target.recordingDirectory)
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
        await target.close()
    }

    /// The production change that makes this test fail: a restore that runs
    /// before the file is written, so the first scan of the watcher finds no
    /// file, or a send that delivers the message a second time.
    @Test("a send to a recorded session writes the file before the restore, and the restore delivers it")
    func aRestoreDeliversTheFileItFinds() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let recorded = try await Self.recordClosedSession(in: fixture)
        let witness = RestoreWitness(inner: fixture.launcher, folder: recorded.folder)
        await fixture.directory.use(launcher: witness)
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await Self.send(to: recorded.id, through: fixture.directory)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: recorded.id, outcome: .delivered)])
        #expect(witness.namesAtRestore == ["\(messageID).md"])
        #expect(await Self.awaitDelivery(of: messageID, reading: &events))
        let restored = try #require(fixture.launcher.sessions.first)
        #expect(await restored.awaitIdle())
        #expect(await restored.transcript.promptTexts == [Self.text])
        #expect(try Self.waitingNames(of: restored).isEmpty)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a restore that
    /// throws and leaves the file in the inbox, so a message with a `refused`
    /// receipt is delivered at a later open.
    @Test("a restore that throws removes the file, so a refused message is not delivered later")
    func aFailedRestoreLeavesNoFile() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let recorded = try await Self.recordClosedSession(in: fixture)
        let failing = FakeSessionLauncher(profile: fixture.profile, restoreError: RestoreFailure())
        let witness = RestoreWitness(inner: failing, folder: recorded.folder)
        await fixture.directory.use(launcher: witness)

        let receipts = try await Self.send(to: recorded.id, through: fixture.directory)

        #expect(
            receipts == [
                SessionSendReceipt(target: recorded.id, outcome: .refused, reason: String(describing: RestoreFailure()))
            ])
        #expect(witness.namesAtRestore.count == 1)
        #expect(try SessionInboxFile.pending(in: recorded.folder).isEmpty)
        await fixture.close([])
    }

    // MARK: - The watcher

    /// The production change that makes this test fail: a registration that
    /// starts no watcher on the inbox folder, so a file waits for a call of
    /// the scan.
    @Test("a file moved into the inbox of a live idle session is delivered with no call to send or scan")
    func aFileMovedIntoTheInboxIsDelivered() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let target = fixture.makeSession()

        let id = try Self.writeFile(to: target, chainDepth: Self.fileChainDepth)

        #expect(await Self.awaitDelivery(of: id, reading: &events))
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        #expect(try await fixture.directory.inbox(of: target.id, markRead: false).map(\.id) == [id])
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a watcher that
    /// waits for the first event before it scans, so a file that arrived
    /// while no process owned the session waits.
    @Test("a file in the inbox before the registration is delivered at the start of the watcher")
    func aFileBeforeTheRegistrationIsDeliveredAtStart() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        fixture.directory.unregister(target.id)
        let id = try Self.writeFile(to: target)
        var events = fixture.directory.events().makeAsyncIterator()

        fixture.directory.register(target, kind: .root, parentID: nil)

        #expect(await Self.awaitDelivery(of: id, reading: &events))
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        #expect(try Self.waitingNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a scan that reads a
    /// dot file, a temporary file or a file that is not `.md`.
    @Test("a temporary file, a dot file and a file that is not markdown are ignored")
    func ignoredNamesAreNotDelivered() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let target = fixture.makeSession()
        let inbox = SessionInboxFile.directory(in: target.recordingDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for name in Self.ignoredNames {
            try Self.fileWithoutFrontmatter.write(
                to: inbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let id = try Self.writeFile(to: target)

        #expect(await Self.awaitDelivery(of: id, reading: &events))
        #expect(try await fixture.directory.inbox(of: target.id, markRead: false).map(\.id) == [id])
        #expect(try Self.names(in: inbox) == Self.ignoredNames.sorted())
        #expect(Self.rejectedNames(of: target).isEmpty)
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a `close()` that
    /// leaves the watcher open.
    @Test("the watcher stops at close, and a later file is not delivered")
    func theWatcherStopsAtClose() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        #expect(fixture.directory.openInboxWatcherCount == 1)
        var events = fixture.directory.events().makeAsyncIterator()

        await target.close()
        let id = try Self.writeFile(to: target)
        fixture.directory.emit(Self.marker)

        #expect(fixture.directory.openInboxWatcherCount == 0)
        #expect(await events.next(through: Self.marker) == [Self.marker])
        #expect(try Self.waitingNames(of: target) == ["\(id).md"])
        await fixture.close([])
    }

    /// The production change that makes this test fail: an archive that
    /// leaves the watcher open.
    @Test("the watcher stops at archive, and a later file is not delivered")
    func theWatcherStopsAtArchive() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        #expect(fixture.directory.openInboxWatcherCount == 1)
        var events = fixture.directory.events().makeAsyncIterator()

        _ = try await fixture.directory.archive(target.id, by: .user(clientID: Self.clientID))
        let id = try Self.writeFile(to: target)
        fixture.directory.emit(Self.marker)

        #expect(fixture.directory.openInboxWatcherCount == 0)
        let received = await events.next(through: Self.marker)
        #expect(!received.contains { if case .messageDelivered = $0 { true } else { false } })
        #expect(try Self.waitingNames(of: target) == ["\(id).md"])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a second
    /// registration that starts a second watcher and drops the first, or that
    /// replaces it.
    @Test("two registrations of one session keep one watcher, and a file is delivered one time")
    func twoRegistrationsKeepOneWatcher() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let target = fixture.makeSession()

        fixture.directory.register(target, kind: .root, parentID: nil)
        let id = try Self.writeFile(to: target)

        #expect(fixture.directory.openInboxWatcherCount == 1)
        #expect(await Self.awaitDelivery(of: id, reading: &events))
        fixture.directory.emit(Self.marker)
        let afterwards = await events.next(through: Self.marker)
        #expect(!afterwards.contains { if case .messageDelivered = $0 { true } else { false } })
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [Self.text])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a watcher for a
    /// session that has no folder to watch.
    @Test("a memory-only session starts no watcher")
    func aMemoryOnlySessionStartsNoWatcher() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryInboxTests-memory")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch)

        let target = profile.standard.makeSession(configuration: SessionConfiguration())

        #expect(router.sessionDirectory.openInboxWatcherCount == 0)
        await target.close()
        withExtendedLifetime(router) {}
    }

    // MARK: - Helpers of the watcher

    /// Reads the directory events until the delivery of the message `id`.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - events: The iterator of a stream of ``RouterSessionDirectory/events()``
    ///     that was open before the file came.
    /// - Returns: `true` when `messageDelivered` of the message came, `false`
    ///   when the stream ended first.
    private static func awaitDelivery(
        of id: MailID, reading events: inout AsyncStream<SessionDirectoryEvent>.Iterator
    ) async -> Bool {
        while let event = await events.next() {
            if case .messageDelivered(let message) = event, message.id == id { return true }
        }
        return false
    }

    /// The names of the files in the inbox folder. The `rejected/` folder is
    /// not in the result.
    ///
    /// - Parameter folder: The inbox folder.
    /// - Returns: The names, in order.
    /// - Throws: The error of the folder read.
    private static func names(in folder: URL) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return entries.filter { $0 != SessionInboxFile.rejectedDirectoryName }.sorted()
    }
}
