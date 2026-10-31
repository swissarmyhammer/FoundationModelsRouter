import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The `inbox/` folder of one session folder: one Markdown file for each
/// message that is not yet delivered, with YAML frontmatter for the sender
/// and the chain, and the text of the message as the body.
@Suite struct SessionInboxFileTests {
    /// The limit of a message that a test reads, a long one.
    private static let wideLimit = 1_000

    /// A limit lower than the text of ``longText``.
    private static let lowLimit = 10

    /// A chain depth other than the default, so a test sees it read back.
    private static let chainDepth = 3

    /// A text longer than ``lowLimit`` bytes.
    private static let longText = "This text is longer than the low limit."

    /// A message with every field filled, unless a parameter says otherwise.
    ///
    /// - Parameters:
    ///   - sender: The sender. The default is a session.
    ///   - inReplyTo: The message this message answers. The default is a new id.
    ///   - chainDepth: The chain depth. The default is ``chainDepth``.
    ///   - text: The text. The default is a short text.
    ///   - unknownKeys: The unknown keys. The default is two keys.
    /// - Returns: The message.
    private static func makeMessage(
        from sender: SessionMessageSender = .session(ULID.generate()),
        inReplyTo: MailID? = MailID(),
        chainDepth: Int = chainDepth,
        text: String = "Please review the patch.\n\nIt is small.",
        unknownKeys: [String: JSONValue] = ["priority": .number(2), "labels": .array([.string("a"), .string("b")])]
    ) -> SessionInboxMessage {
        SessionInboxMessage(
            id: MailID(), from: sender, inReplyTo: inReplyTo, chainDepth: chainDepth, text: text,
            unknownKeys: unknownKeys)
    }

    /// Writes a file into the `inbox/` folder of `sessionDirectory`.
    ///
    /// - Parameters:
    ///   - text: The text of the file.
    ///   - name: The name of the file.
    ///   - sessionDirectory: The session folder.
    /// - Returns: The URL of the file.
    @discardableResult
    private static func writeRaw(_ text: String, named name: String, in sessionDirectory: URL) throws -> URL {
        let inbox = SessionInboxFile.directory(in: sessionDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent(name, isDirectory: false)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// A session folder that exists.
    private static func makeSessionDirectory() -> URL {
        RouterTestFixtures.makeTempDir(prefix: "SessionInboxFileTests")
    }

    // MARK: - Round trip

    /// A written file reads back with equal id, sender, `inReplyTo`, chain
    /// depth, text and unknown keys.
    @Test func aWrittenFileReadsBackEqual() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage()

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)

        let file = SessionInboxFile.url(of: message.id, in: directory)
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit) == message)
    }

    /// A message with no `inReplyTo` and no unknown keys reads back equal: the
    /// writer leaves the `inReplyTo` key out.
    @Test func aMessageWithNoInReplyToReadsBackEqual() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(inReplyTo: nil, unknownKeys: [:])

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)

        let file = SessionInboxFile.url(of: message.id, in: directory)
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit) == message)
    }

    /// A text of exactly the limit is written and reads back equal.
    @Test func aTextOfExactlyTheLimitReadsBackEqual() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(text: String(repeating: "a", count: Self.lowLimit))

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.lowLimit)

        let file = SessionInboxFile.url(of: message.id, in: directory)
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.lowLimit) == message)
    }

    /// A text longer than the limit is not written, because the read of the
    /// file would reject it. The inbox stays empty.
    @Test func aTextOverTheLimitIsNotWritten() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(text: Self.longText)
        let file = SessionInboxFile.url(of: message.id, in: directory)

        #expect(throws: SessionInboxFileError.bodyTooLong(file: file, limit: Self.lowLimit)) {
            try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.lowLimit)
        }
        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    /// The limit counts UTF-8 bytes, not characters, the same as the read.
    @Test func theLimitOfAWriteCountsBytes() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(text: String(repeating: "\u{00E9}", count: Self.lowLimit))
        let file = SessionInboxFile.url(of: message.id, in: directory)

        #expect(throws: SessionInboxFileError.bodyTooLong(file: file, limit: Self.lowLimit)) {
            try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.lowLimit)
        }
    }

    /// A chain depth below 1 is not written, because the read of the file
    /// would reject it.
    @Test(arguments: [0, -1])
    func aChainDepthBelowOneIsNotWritten(depth: Int) throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(chainDepth: depth)
        let file = SessionInboxFile.url(of: message.id, in: directory)

        #expect(throws: SessionInboxFileError.invalidChainDepth(file: file, value: depth)) {
            try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)
        }
        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    /// An unknown key with the name of a known key is not written, because
    /// the read of the file would give the known key and not this value.
    @Test(arguments: ["id", "from", "inReplyTo", "chainDepth"])
    func anUnknownKeyWithAKnownNameIsNotWritten(name: String) throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(unknownKeys: [name: .string("x")])
        let file = SessionInboxFile.url(of: message.id, in: directory)

        #expect(throws: SessionInboxFileError.reservedUnknownKey(file: file, key: name)) {
            try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)
        }
        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    /// The write makes the `inbox/` folder when it is absent, and leaves no
    /// temporary file after the rename.
    @Test func aWriteMakesTheFolderAndLeavesOnlyTheMessageFile() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage()

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)

        let names = try FileManager.default.contentsOfDirectory(
            atPath: SessionInboxFile.directory(in: directory).path)
        #expect(names == ["\(message.id).md"])
    }

    // MARK: - Sender

    /// A UI sender keeps its client id through the file.
    @Test func aUserSenderWithAClientIDRoundTrips() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(from: .user(clientID: "client-a"))

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)

        let file = SessionInboxFile.url(of: message.id, in: directory)
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit).from == .user(clientID: "client-a"))
    }

    /// The default user sender round trips, in the plain `user` form.
    @Test func theDefaultUserSenderRoundTrips() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(from: .user(clientID: SessionInboxFile.defaultUserClientID))

        try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)

        let file = SessionInboxFile.url(of: message.id, in: directory)
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit) == message)
    }

    /// A UI sender with an empty client id is not written, because the read of
    /// the file would reject `user:` with no client id. The inbox stays empty.
    @Test func aUserSenderWithAnEmptyClientIDIsNotWritten() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = Self.makeMessage(from: .user(clientID: ""))
        let file = SessionInboxFile.url(of: message.id, in: directory)

        #expect(throws: SessionInboxFileError.invalidSender(file: file, value: "user:")) {
            try SessionInboxFile.write(message, to: directory, maxMessageBytes: Self.wideLimit)
        }
        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    /// The sender `user:<clientID>` of a hand-written file is a UI sender, and
    /// the sender `session:<ULID>` is a session.
    @Test func theTwoSenderFormsReadAsTheirCases() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = ULID.generate()
        let user = try Self.writeRaw("---\nfrom: user:client-b\n---\nHello", named: "\(MailID()).md", in: directory)
        let session = try Self.writeRaw(
            "---\nfrom: session:\(sessionID)\n---\nHello", named: "\(MailID()).md", in: directory)

        #expect(try SessionInboxFile.read(user, maxMessageBytes: Self.wideLimit).from == .user(clientID: "client-b"))
        #expect(try SessionInboxFile.read(session, maxMessageBytes: Self.wideLimit).from == .session(sessionID))
    }

    /// The plain sender `user` is the default user sender, the same as a file
    /// with no `from`.
    @Test func thePlainUserSenderIsTheDefaultUserSender() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = try Self.writeRaw("---\nfrom: user\n---\nHello", named: "\(MailID()).md", in: directory)
        let absent = try Self.writeRaw("---\nchainDepth: 2\n---\nHello", named: "\(MailID()).md", in: directory)

        let expected = SessionMessageSender.user(clientID: SessionInboxFile.defaultUserClientID)
        #expect(try SessionInboxFile.read(plain, maxMessageBytes: Self.wideLimit).from == expected)
        #expect(try SessionInboxFile.read(absent, maxMessageBytes: Self.wideLimit).from == expected)
    }

    /// A file with a sender that is not one of the forms does not parse.
    @Test(arguments: ["robot", "session:not-a-ulid", "user:", "agent:x"])
    func aBadSenderDoesNotParse(sender: String) throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw("---\nfrom: \"\(sender)\"\n---\nHello", named: "\(MailID()).md", in: directory)

        #expect(throws: SessionInboxFileError.invalidSender(file: file, value: sender)) {
            try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)
        }
    }

    // MARK: - Defaults and ids

    /// A file with only a sender and a text takes the first chain depth, no
    /// `inReplyTo` and no unknown keys.
    @Test func aFileWithNoOptionalKeysTakesTheDefaults() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MailID()
        let file = try Self.writeRaw("---\nfrom: user\n---\nHello\n", named: "\(id).md", in: directory)

        let message = try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)

        #expect(message.chainDepth == RouterSessionDirectory.firstChainDepth)
        #expect(message.inReplyTo == nil)
        #expect(message.unknownKeys.isEmpty)
        #expect(message.text == "Hello\n")
    }

    /// A file with no `id` takes the id from its name.
    @Test func aFileWithNoIDTakesTheIDFromItsName() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MailID()
        let file = try Self.writeRaw("---\nfrom: user\n---\nHello", named: "\(id).md", in: directory)

        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit).id == id)
    }

    /// A file with an `id` in the frontmatter keeps it, whatever its name.
    @Test func anIDInTheFrontmatterWinsOverTheName() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MailID()
        let file = try Self.writeRaw("---\nid: \(id)\nfrom: user\n---\nHello", named: "note.md", in: directory)

        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit).id == id)
    }

    /// A file with no `id` and a name that is not a ULID does not parse.
    @Test func aFileWithNoIDAndAPlainNameDoesNotParse() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw("---\nfrom: user\n---\nHello", named: "note.md", in: directory)

        #expect(throws: SessionInboxFileError.missingID(file: file)) {
            try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)
        }
    }

    // MARK: - Unknown keys

    /// A key that the format does not know stays in the unknown keys, with its
    /// value.
    @Test func anUnknownKeyIsKept() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MailID()
        let text = "---\nfrom: user\nsubject: Patch\nretries: 2\nurgent: true\n---\nHello"
        let file = try Self.writeRaw(text, named: "\(id).md", in: directory)

        let message = try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)

        #expect(
            message.unknownKeys == ["subject": .string("Patch"), "retries": .number(2), "urgent": .bool(true)])
    }

    // MARK: - Pending

    /// The pending files are the `*.md` files of `inbox/`, in the order of
    /// their names. A temporary file, a dot file, a file with another
    /// extension and the `rejected/` folder are not pending.
    @Test func pendingListsOnlyMarkdownFilesSortedByName() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["c.md", "a.md", "b.md", ".d.md", ".e.md.tmp", "f.md.tmp", "g.txt", "h"] {
            try Self.writeRaw("x", named: name, in: directory)
        }
        try FileManager.default.createDirectory(
            at: SessionInboxFile.rejectedDirectory(in: directory), withIntermediateDirectories: true)

        let names = try SessionInboxFile.pending(in: directory).map(\.lastPathComponent)

        #expect(names == ["a.md", "b.md", "c.md"])
    }

    /// Messages that a writer wrote one after the other are pending in the
    /// order of their ids.
    @Test func pendingReturnsMessagesInTheOrderOfTheirIDs() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.makeMessage()
        let second = Self.makeMessage()
        try SessionInboxFile.write(second, to: directory, maxMessageBytes: Self.wideLimit)
        try SessionInboxFile.write(first, to: directory, maxMessageBytes: Self.wideLimit)

        let names = try SessionInboxFile.pending(in: directory).map(\.lastPathComponent)

        #expect(names == [first, second].map { "\($0.id).md" }.sorted())
    }

    /// A session folder with no `inbox/` has nothing pending.
    @Test func aFolderWithNoInboxHasNothingPending() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    // MARK: - Files that do not parse

    /// A file with no frontmatter does not parse.
    @Test func aFileWithNoFrontmatterDoesNotParse() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw("Just text.", named: "\(MailID()).md", in: directory)

        #expect(throws: SessionInboxFileError.missingFrontmatter(file: file)) {
            try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)
        }
    }

    /// A chain depth below 1 does not parse.
    @Test(arguments: [0, -1])
    func aChainDepthBelowOneDoesNotParse(depth: Int) throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw(
            "---\nfrom: user\nchainDepth: \(depth)\n---\nHello", named: "\(MailID()).md", in: directory)

        #expect(throws: SessionInboxFileError.invalidChainDepth(file: file, value: depth)) {
            try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)
        }
    }

    /// A text longer than the limit that the caller gives does not parse, and
    /// the same file parses with a wide limit.
    @Test func aTextOverTheGivenLimitDoesNotParse() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw(
            "---\nfrom: user\n---\n\(Self.longText)", named: "\(MailID()).md", in: directory)

        #expect(throws: SessionInboxFileError.bodyTooLong(file: file, limit: Self.lowLimit)) {
            try SessionInboxFile.read(file, maxMessageBytes: Self.lowLimit)
        }
        #expect(try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit).text == Self.longText)
    }

    /// Frontmatter that is not a mapping of the known keys does not parse.
    @Test func frontmatterThatDoesNotDecodeDoesNotParse() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw(
            "---\nfrom: user\ninReplyTo: not-a-ulid\n---\nHello", named: "\(MailID()).md", in: directory)

        #expect {
            try SessionInboxFile.read(file, maxMessageBytes: Self.wideLimit)
        } throws: { error in
            guard case SessionInboxFileError.undecodable(let failed, _) = error else { return false }
            return failed == file
        }
    }

    // MARK: - Reject

    /// A rejected file moves to `inbox/rejected/`, keeps its bytes, and is no
    /// longer pending.
    @Test func aRejectedFileMovesToTheRejectedFolder() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writeRaw("Just text.", named: "a.md", in: directory)

        let moved = try SessionInboxFile.reject(file, in: directory)

        #expect(moved == SessionInboxFile.rejectedDirectory(in: directory).appendingPathComponent("a.md"))
        #expect(try String(contentsOf: moved, encoding: .utf8) == "Just text.")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try SessionInboxFile.pending(in: directory).isEmpty)
    }

    /// A file that is rejected with the name of a file that is rejected
    /// already does not replace it.
    @Test func aRejectedFileDoesNotReplaceAnEarlierRejectedFile() throws {
        let directory = Self.makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try Self.writeRaw("first", named: "a.md", in: directory)
        let firstMoved = try SessionInboxFile.reject(first, in: directory)
        let second = try Self.writeRaw("second", named: "a.md", in: directory)

        let secondMoved = try SessionInboxFile.reject(second, in: directory)

        #expect(secondMoved != firstMoved)
        #expect(try String(contentsOf: firstMoved, encoding: .utf8) == "first")
        #expect(try String(contentsOf: secondMoved, encoding: .utf8) == "second")
    }
}
