import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The scan of the `inbox/` folder of a live durable session
/// (``RouterSessionDirectory/scanInbox(of:)``): a file there is a message
/// that goes through the same delivery as a send. The file is removed after
/// the delivery, a file whose id the ledger holds is removed with no second
/// delivery, a file that does not parse moves to `inbox/rejected/`, and a
/// refusal or a ledger read error leaves the file where it is.
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
}
