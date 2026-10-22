import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The record of the messages to one session (ROUTER-4): `messages.jsonl` in
/// the recording directory of a durable session, one line for each delivered
/// message and one later line for each read mark, and the memory of a
/// memory-only session.
@Suite struct SessionMessageLedgerTests {
    /// The session the messages of a test go to.
    private static let recipient = ULID.generate()

    /// The UI client that sends the UI messages of a test.
    private static let clientID = "client-a"

    /// A delivery time inside a second, on a whole millisecond — the
    /// precision of the ISO 8601 dates of a `JSONLFile` line — so a test sees
    /// the time read back exactly, milliseconds included.
    private static let sentAt = DateTime(millisecondsSince1970: 1_761_307_200_456).date

    /// The chain depth of the messages of a test, other than the depth 1 of
    /// a UI message, so a test sees the depth read back.
    private static let chainDepth = 2

    /// A message to ``recipient``.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - sender: The sender. The default is a UI with ``clientID``.
    ///   - inReplyTo: The message it answers. The default is none.
    /// - Returns: The message, not read.
    private static func message(
        _ text: String,
        from sender: SessionMessageSender = .user(clientID: clientID),
        inReplyTo: MailID? = nil
    ) -> SessionMessage {
        SessionMessage(
            id: MailID(), from: sender, to: recipient, text: text, inReplyTo: inReplyTo, sentAt: sentAt,
            chainDepth: chainDepth)
    }

    /// The `messages.jsonl` of `directory`.
    private static func ledgerFile(in directory: URL) -> URL {
        directory.appendingPathComponent(SessionMessageLedger.fileName, isDirectory: false)
    }

    // MARK: - Read back

    /// A message recorded in a directory reads back from a new load with each
    /// field: the UI client id of the sender, `inReplyTo`, the chain depth and
    /// the time.
    @Test func aRecordedMessageReadsBackFromANewLoad() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorded = Self.message("Please review the patch.", inReplyTo: MailID())
        var ledger = try SessionMessageLedger.load(from: directory)

        ledger.record(recorded)

        let loaded = try SessionMessageLedger.load(from: directory)
        #expect(loaded.unread == [recorded])
        #expect(loaded.unread.first?.from == .user(clientID: Self.clientID))
    }

    /// A read mark reads back from a new load: the message is read, and it
    /// leaves the unread messages.
    @Test func aReadMarkReadsBackFromANewLoad() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.message("first")
        let second = Self.message("second", from: .session(ULID.generate()))
        var ledger = try SessionMessageLedger.load(from: directory)
        ledger.record(first)
        ledger.record(second)

        ledger.markRead([first.id])

        let loaded = try SessionMessageLedger.load(from: directory)
        #expect(loaded.unread == [second])
        #expect(loaded.message(first.id)?.isRead == true)
    }

    /// Each read mark is a later line: the file holds one line for each
    /// delivery and one for each mark.
    @Test func eachDeliveryAndEachReadMarkIsOneLine() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.message("first")
        let second = Self.message("second")
        var ledger = try SessionMessageLedger.load(from: directory)
        ledger.record(first)
        ledger.record(second)

        ledger.markRead([first.id, second.id])

        let text = try String(contentsOf: Self.ledgerFile(in: directory), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)
    }

    /// A mark of an id the ledger does not hold, and a second mark of a read
    /// message, write no line.
    @Test func aMarkThatChangesNothingWritesNoLine() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.message("first")
        var ledger = try SessionMessageLedger.load(from: directory)
        ledger.record(first)
        ledger.markRead([first.id])

        ledger.markRead([first.id, MailID()])

        let text = try String(contentsOf: Self.ledgerFile(in: directory), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    /// The unread messages come in the order of their delivery.
    @Test func theUnreadMessagesComeInDeliveryOrder() throws {
        var ledger = try SessionMessageLedger.load(from: nil)
        let messages = ["first", "second", "third"].map { Self.message($0) }

        for message in messages {
            ledger.record(message)
        }

        #expect(ledger.unread == messages)
    }

    // MARK: - Memory only

    /// A ledger with no directory keeps its messages and its read marks in
    /// memory.
    @Test func aMemoryOnlyLedgerKeepsItsMessagesInMemory() throws {
        var ledger = try SessionMessageLedger.load(from: nil)
        let first = Self.message("first")
        let second = Self.message("second")
        ledger.record(first)
        ledger.record(second)

        ledger.markRead([second.id])

        #expect(ledger.unread == [first])
        #expect(ledger.message(second.id)?.isRead == true)
    }

    /// A directory with no `messages.jsonl` loads as an empty ledger and
    /// writes no file.
    @Test func aDirectoryWithNoFileLoadsEmpty() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try SessionMessageLedger.load(from: directory)

        #expect(ledger.unread.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.ledgerFile(in: directory).path))
    }

    // MARK: - Lookup

    /// A lookup of an id the ledger does not hold gives `nil`.
    @Test func aLookupOfAnUnknownIdGivesNil() throws {
        var ledger = try SessionMessageLedger.load(from: nil)
        ledger.record(Self.message("first"))

        #expect(ledger.message(MailID()) == nil)
    }

    // MARK: - Damage

    /// A torn final line, the artifact of a crash during an append, is
    /// dropped, and each earlier message stays.
    @Test func aTornFinalLineIsDropped() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Self.message("kept")
        var ledger = try SessionMessageLedger.load(from: directory)
        ledger.record(kept)
        let file = Self.ledgerFile(in: directory)
        try (try Data(contentsOf: file) + Data(#"{"delivered":{"mess"#.utf8)).write(to: file)

        let loaded = try SessionMessageLedger.load(from: directory)

        #expect(loaded.unread == [kept])
    }

    /// A whole line that does not decode before the final line is skipped,
    /// and the load keeps each message around it.
    @Test func aCorruptEarlierLineIsSkipped() throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionMessageLedgerTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json\n".utf8).write(to: Self.ledgerFile(in: directory))
        let valid = Self.message("valid")
        var ledger = try SessionMessageLedger.load(from: directory)
        ledger.record(valid)

        let loaded = try SessionMessageLedger.load(from: directory)

        #expect(loaded.unread == [valid])
    }
}
