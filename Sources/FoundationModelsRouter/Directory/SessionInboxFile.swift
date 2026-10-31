import Foundation
import FoundationModelsExtras

/// A failure to read one file of the `inbox/` folder of a session folder.
///
/// A file that fails is not a message: ``SessionInboxFile/reject(_:in:)``
/// moves it out of the way.
enum SessionInboxFileError: Error, Equatable, LocalizedError {
    /// `file` is not UTF-8 text.
    case notText(file: URL)

    /// `file` holds no YAML frontmatter, so it holds no sender and no chain.
    case missingFrontmatter(file: URL)

    /// The frontmatter of `file` does not decode: the YAML does not parse, or
    /// a key has a value of the wrong kind.
    case undecodable(file: URL, description: String)

    /// `file` has no `id` key, and its name is not a ULID.
    case missingID(file: URL)

    /// The `from` of `file` is not `session:<ULID>`, `user:<clientID>` or
    /// `user`.
    case invalidSender(file: URL, value: String)

    /// The `chainDepth` of `file` is less than
    /// ``SessionInboxFile/lowestChainDepth``.
    case invalidChainDepth(file: URL, value: Int)

    /// The text of `file` is longer than `limit` bytes.
    case bodyTooLong(file: URL, limit: Int)

    /// A localized message describing what error occurred.
    var errorDescription: String? {
        switch self {
        case .notText(let file):
            return "Inbox file \(file.path) is not UTF-8 text."
        case .missingFrontmatter(let file):
            return "Inbox file \(file.path) has no frontmatter, so it holds no sender and no chain depth."
        case .undecodable(let file, let description):
            return "The frontmatter of inbox file \(file.path) does not decode: \(description)"
        case .missingID(let file):
            return "Inbox file \(file.path) has no id, and its name is not a ULID."
        case .invalidSender(let file, let value):
            return
                "The sender \"\(value)\" of inbox file \(file.path) is not session:<ULID>, user:<clientID> or user."
        case .invalidChainDepth(let file, let value):
            return
                "The chain depth \(value) of inbox file \(file.path) is less than \(SessionInboxFile.lowestChainDepth)."
        case .bodyTooLong(let file, let limit):
            return "The text of inbox file \(file.path) is longer than \(limit) bytes."
        }
    }
}

/// One message of the `inbox/` folder of a session folder, as the file holds
/// it.
struct SessionInboxMessage: Equatable, Sendable {
    /// The id of the message. The ledger and the mail of the session keep it.
    var id: MailID

    /// Who sent the message.
    var from: SessionMessageSender

    /// The message this message answers, or `nil`.
    var inReplyTo: MailID?

    /// The depth of the chain of messages that this message ends. Not less
    /// than ``SessionInboxFile/lowestChainDepth``.
    var chainDepth: Int

    /// The text of the message: the body of the file, byte for byte.
    var text: String

    /// The frontmatter keys that the format does not know, with their values.
    var unknownKeys: [String: JSONValue] = [:]
}

/// The file format of one message in the `inbox/` folder of a session
/// folder (see `mailbox-plan.md`).
///
/// The folder is `<session folder>/inbox/`, and a message is one file in it:
/// `<ULID>.md`, YAML frontmatter and then the text of the message. The
/// frontmatter keys are `id`, `from`, `inReplyTo` and `chainDepth`. A key
/// that is not one of them is kept in ``SessionInboxMessage/unknownKeys``, so
/// a new header needs no change of the schema. A file that does not parse
/// moves to `inbox/rejected/`. The format uses the Extras `FrontmatterDocument`,
/// as ``SessionIndexFile`` does.
///
/// A writer, the Router included, writes the file to `inbox/.<ULID>.md.tmp`
/// and then renames it to `inbox/<ULID>.md`. The rename is atomic, and
/// ``pending(in:)`` skips dot files, so a reader never sees part of a file.
/// The sort of the names is the order of arrival, because a ULID sorts by
/// time.
///
/// The `from` key has three forms:
/// - `session:<ULID>` is ``SessionMessageSender/session(_:)``.
/// - `user:<clientID>` is ``SessionMessageSender/user(clientID:)``. The Router
///   writes this form for a UI sender, so the client id is not lost.
/// - `user` is the default of a hand-written file, and also the value of a
///   file with no `from`. It is `user:` with ``defaultUserClientID``.
///
/// A `from` is not authenticated: the trust boundary is the user account that
/// owns the folder.
enum SessionInboxFile {
    /// The name of the inbox folder in a session folder.
    static let directoryName = "inbox"

    /// The name of the folder in the inbox folder for the files that do not
    /// parse.
    static let rejectedDirectoryName = "rejected"

    /// The extension of a message file, without the dot.
    static let fileExtension = "md"

    /// The start of the name of a file that a writer has not finished: a dot,
    /// which hides it from ``pending(in:)``.
    static let temporaryPrefix = "."

    /// The end of the name of a file that a writer has not finished.
    static let temporarySuffix = ".tmp"

    /// The client id of the sender `user` with no client id.
    static let defaultUserClientID = "user"

    /// The least value of a chain depth. A message that no message answers
    /// has ``RouterSessionDirectory/firstChainDepth``.
    static let lowestChainDepth = 1

    /// The `inbox/` folder of a session folder.
    ///
    /// - Parameter sessionDirectory: The session folder.
    /// - Returns: The folder URL. The folder may not exist.
    static func directory(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The `inbox/rejected/` folder of a session folder.
    ///
    /// - Parameter sessionDirectory: The session folder.
    /// - Returns: The folder URL. The folder may not exist.
    static func rejectedDirectory(in sessionDirectory: URL) -> URL {
        directory(in: sessionDirectory).appendingPathComponent(rejectedDirectoryName, isDirectory: true)
    }

    /// The file of a message.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - sessionDirectory: The session folder.
    /// - Returns: `inbox/<ULID>.md` in the session folder.
    static func url(of id: MailID, in sessionDirectory: URL) -> URL {
        directory(in: sessionDirectory)
            .appendingPathComponent("\(id)", isDirectory: false)
            .appendingPathExtension(fileExtension)
    }

    /// Writes a message to the inbox of a session folder: first to
    /// `inbox/.<ULID>.md.tmp`, then with a rename to `inbox/<ULID>.md`.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - sessionDirectory: The session folder. It must exist; the `inbox/`
    ///     folder is made when it is absent.
    /// - Throws: `FrontmatterDocumentSaveError` when the frontmatter does not
    ///   encode or the temporary file does not save, or the error of the
    ///   folder make or of the rename. A write that fails removes its
    ///   temporary file.
    static func write(_ message: SessionInboxMessage, to sessionDirectory: URL) throws {
        let file = url(of: message.id, in: sessionDirectory)
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(temporaryPrefix + file.lastPathComponent + temporarySuffix, isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FrontmatterDocument(metadata: Header(message), content: message.text).save(to: temporary)
        do {
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The files that wait in the inbox of a session folder.
    ///
    /// - Parameter sessionDirectory: The session folder.
    /// - Returns: The files whose name ends in `.md`, in the order of their
    ///   names. A dot file, a file with another extension, a folder (the
    ///   `rejected/` folder included) and a temporary file are not in the
    ///   result. The result is empty when the `inbox/` folder is absent.
    /// - Throws: The error of the folder read.
    static func pending(in sessionDirectory: URL) throws -> [URL] {
        let inbox = directory(in: sessionDirectory)
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isRegularFileKey])
        return entries.filter(isPendingFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads one message file.
    ///
    /// - Parameters:
    ///   - file: A file of the inbox folder.
    ///   - maxMessageBytes: The longest text, in UTF-8 bytes. This is
    ///     `SessionMessageLimits.maxMessageBytes` of the directory the inbox
    ///     belongs to.
    /// - Returns: The message. A file with no `id` has the id of its name.
    /// - Throws: ``SessionInboxFileError`` when the file does not parse, or
    ///   the error of the read.
    static func read(_ file: URL, maxMessageBytes: Int) throws -> SessionInboxMessage {
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw SessionInboxFileError.notText(file: file)
        }
        let parts = FrontmatterDocument.split(text: text)
        guard let frontmatter = parts.frontmatter else {
            throw SessionInboxFileError.missingFrontmatter(file: file)
        }
        guard parts.body.utf8.count <= maxMessageBytes else {
            throw SessionInboxFileError.bodyTooLong(file: file, limit: maxMessageBytes)
        }
        let header = try header(of: frontmatter, in: file)
        return try message(of: header, body: parts.body, file: file)
    }

    /// Moves a file that does not parse to `inbox/rejected/`. The file is not
    /// deleted. A file already there with the same name stays: the moved file
    /// gets a new ULID in front of its name.
    ///
    /// - Parameters:
    ///   - file: A file of the inbox folder.
    ///   - sessionDirectory: The session folder.
    /// - Returns: The new URL of the file.
    /// - Throws: The error of the folder make or of the move.
    @discardableResult
    static func reject(_ file: URL, in sessionDirectory: URL) throws -> URL {
        let rejected = rejectedDirectory(in: sessionDirectory)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        var target = rejected.appendingPathComponent(file.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: target.path) {
            target = rejected.appendingPathComponent("\(MailID()).\(file.lastPathComponent)", isDirectory: false)
        }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// Whether a folder entry is a message that waits.
    ///
    /// - Parameter entry: An entry of the inbox folder.
    /// - Returns: `true` for a regular file that is not a dot file and whose
    ///   name ends in `.md`.
    private static func isPendingFile(_ entry: URL) -> Bool {
        let name = entry.lastPathComponent
        let isRegularFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        return isRegularFile && !name.hasPrefix(temporaryPrefix) && name.hasSuffix(".\(fileExtension)")
    }

    /// Decodes the header of a frontmatter.
    ///
    /// - Parameters:
    ///   - frontmatter: The YAML text of the frontmatter.
    ///   - file: The file the frontmatter is from, for the error.
    /// - Returns: The header.
    /// - Throws: ``SessionInboxFileError/undecodable(file:description:)`` when
    ///   the YAML does not parse or does not decode as a header.
    private static func header(of frontmatter: String, in file: URL) throws -> Header {
        do {
            return try YAMLValue.parse(frontmatter).decoded(as: Header.self)
        } catch {
            throw SessionInboxFileError.undecodable(file: file, description: String(describing: error))
        }
    }

    /// Makes the message of a header and a body, and checks the header.
    ///
    /// - Parameters:
    ///   - header: The decoded frontmatter.
    ///   - body: The text after the frontmatter.
    ///   - file: The file, for the error and for the id when the header has
    ///     none.
    /// - Returns: The message.
    /// - Throws: ``SessionInboxFileError`` when there is no id, the sender is
    ///   not valid or the chain depth is less than ``lowestChainDepth``.
    private static func message(of header: Header, body: String, file: URL) throws -> SessionInboxMessage {
        guard let id = header.id ?? idFromName(of: file) else {
            throw SessionInboxFileError.missingID(file: file)
        }
        let chainDepth = header.chainDepth ?? RouterSessionDirectory.firstChainDepth
        guard chainDepth >= lowestChainDepth else {
            throw SessionInboxFileError.invalidChainDepth(file: file, value: chainDepth)
        }
        let from = try sender(of: header, in: file)
        return SessionInboxMessage(
            id: id, from: from, inReplyTo: header.inReplyTo, chainDepth: chainDepth, text: body,
            unknownKeys: header.unknownKeys)
    }

    /// The sender of a header.
    ///
    /// - Parameters:
    ///   - header: The decoded frontmatter.
    ///   - file: The file, for the error.
    /// - Returns: The sender of the `from` key, or the default user sender
    ///   when the header has no `from`.
    /// - Throws: ``SessionInboxFileError/invalidSender(file:value:)`` when the
    ///   `from` is not one of the three forms.
    private static func sender(of header: Header, in file: URL) throws -> SessionMessageSender {
        guard let value = header.from else { return .user(clientID: defaultUserClientID) }
        guard let sender = SessionMessageSender(inboxText: value) else {
            throw SessionInboxFileError.invalidSender(file: file, value: value)
        }
        return sender
    }

    /// The id that the name of a file gives.
    ///
    /// - Parameter file: A message file.
    /// - Returns: The id, or `nil` when the name without its extension is not
    ///   a ULID.
    private static func idFromName(of file: URL) -> MailID? {
        ULID(file.deletingPathExtension().lastPathComponent).map(MailID.init)
    }

    /// The frontmatter of a message file.
    ///
    /// Each key but `id` is optional, and a key that is not here goes to
    /// ``unknownKeys``.
    private struct Header: Codable {
        /// The key names the format knows.
        private enum KnownKey: String {
            case id, from, inReplyTo, chainDepth
        }

        /// A key by name, for a mapping that has any key. A mapping has no
        /// integer keys.
        private struct AnyKey: CodingKey {
            let stringValue: String

            var intValue: Int? { nil }

            init(stringValue: String) { self.stringValue = stringValue }

            init?(intValue: Int) { nil }

            init(_ known: KnownKey) { self.stringValue = known.rawValue }
        }

        /// The `id` key.
        var id: MailID?

        /// The `from` key, in the text form of ``SessionMessageSender/inboxText``.
        var from: String?

        /// The `inReplyTo` key.
        var inReplyTo: MailID?

        /// The `chainDepth` key.
        var chainDepth: Int?

        /// The keys that are not one of the known keys.
        var unknownKeys: [String: JSONValue]

        /// Makes the header of a message: each known key but `inReplyTo` has
        /// a value.
        ///
        /// - Parameter message: The message.
        init(_ message: SessionInboxMessage) {
            id = message.id
            from = message.from.inboxText
            inReplyTo = message.inReplyTo
            chainDepth = message.chainDepth
            unknownKeys = message.unknownKeys
        }

        /// Decodes the known keys, and keeps the other keys.
        ///
        /// - Parameter decoder: The decoder of the frontmatter mapping.
        /// - Throws: The error of a key of the wrong kind.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            id = try container.decodeIfPresent(MailID.self, forKey: AnyKey(.id))
            from = try container.decodeIfPresent(String.self, forKey: AnyKey(.from))
            inReplyTo = try container.decodeIfPresent(MailID.self, forKey: AnyKey(.inReplyTo))
            chainDepth = try container.decodeIfPresent(Int.self, forKey: AnyKey(.chainDepth))
            unknownKeys = [:]
            for key in container.allKeys where KnownKey(rawValue: key.stringValue) == nil {
                unknownKeys[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }

        /// Encodes the known keys that have a value, and then the other keys.
        /// A key of ``unknownKeys`` with the name of a known key is dropped:
        /// the known key wins.
        ///
        /// - Parameter encoder: The encoder of the frontmatter mapping.
        /// - Throws: The error of an encode.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            try container.encodeIfPresent(id, forKey: AnyKey(.id))
            try container.encodeIfPresent(from, forKey: AnyKey(.from))
            try container.encodeIfPresent(inReplyTo, forKey: AnyKey(.inReplyTo))
            try container.encodeIfPresent(chainDepth, forKey: AnyKey(.chainDepth))
            for (name, value) in unknownKeys where KnownKey(rawValue: name) == nil {
                try container.encode(value, forKey: AnyKey(stringValue: name))
            }
        }
    }
}

/// The text form of a sender in the `from` key of a message file.
extension SessionMessageSender {
    /// The start of the text of a session sender.
    fileprivate static let sessionPrefix = "session:"

    /// The text of a user sender with no client id.
    fileprivate static let userText = "user"

    /// The start of the text of a user sender with a client id.
    fileprivate static let userPrefix = "user:"

    /// The `from` text of the sender: `session:<ULID>`, or `user:<clientID>`,
    /// or `user` for the default client id of ``SessionInboxFile``.
    fileprivate var inboxText: String {
        switch self {
        case .session(let id):
            return Self.sessionPrefix + id.ulidString
        case .user(let clientID):
            return clientID == SessionInboxFile.defaultUserClientID ? Self.userText : Self.userPrefix + clientID
        }
    }

    /// Makes the sender of a `from` text.
    ///
    /// - Parameter inboxText: `session:<ULID>`, `user:<clientID>` or `user`.
    ///   A client id is not empty.
    fileprivate init?(inboxText: String) {
        if inboxText == Self.userText {
            self = .user(clientID: SessionInboxFile.defaultUserClientID)
        } else if inboxText.hasPrefix(Self.sessionPrefix),
            let id = ULID(String(inboxText.dropFirst(Self.sessionPrefix.count)))
        {
            self = .session(id)
        } else if inboxText.hasPrefix(Self.userPrefix), inboxText.count > Self.userPrefix.count {
            self = .user(clientID: String(inboxText.dropFirst(Self.userPrefix.count)))
        } else {
            return nil
        }
    }
}
