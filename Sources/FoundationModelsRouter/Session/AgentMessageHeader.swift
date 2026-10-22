import Foundation
import FoundationModelsExtras

/// The facts of the sender of an agent message, which the session directory
/// writes before the text of the message (section 10.1 of `session.md`).
///
/// The session that renders the prompt cannot read the directory, and the
/// mail body ``MailBody/agentMessage(from:content:)`` carries only the
/// session id of the sender. So the directory puts the facts it knows in the
/// content of the mail, as the first line (``AgentMessageContent``), and the
/// renderer (``Mail/promptText``) shows them outside the fence of untrusted
/// text.
struct AgentMessageHeader: Codable, Sendable, Equatable {
    /// The session id of the sender. The renderer trusts a header only when
    /// this id is the sender of the mail body.
    let sender: ULID

    /// The id of the agent of the sender, or `nil` when the directory knows
    /// no live session with the id ``sender``.
    let agentID: String?

    /// The display name of the agent of the sender, or `nil`.
    let agentName: String?

    /// The title of the sender, or `nil`.
    let title: String?

    /// The path of the working folder of the sender, or `nil` when the
    /// directory knows no live session with the id ``sender``.
    let folder: String?

    /// The id of the message that this message answers, or `nil` for a
    /// message that answers none.
    let inReplyTo: MailID?
}

extension AgentMessageHeader {
    /// The radix of the scalar value in the escape of a character that would
    /// break a fact line (``quoted(_:)``).
    private static let escapeRadix = 16

    /// The general categories of the characters that end a line, or that a
    /// reader can take for the end of a line: the control characters (line
    /// feed, carriage return, next line and the rest), the line separator
    /// and the paragraph separator.
    private static let lineBreakingCategories: [Unicode.GeneralCategory] = [
        .control, .lineSeparator, .paragraphSeparator,
    ]

    /// Makes the header of a message from `sender` with the facts of its
    /// summary.
    ///
    /// - Parameters:
    ///   - sender: The session id of the sender.
    ///   - summary: The live summary of the sender, or `nil` when the
    ///     directory knows no live session with the id. The header then names
    ///     only the id and `inReplyTo`.
    ///   - inReplyTo: The id of the message that this message answers, or
    ///     `nil`.
    init(sender: ULID, summary: SessionSummary?, inReplyTo: MailID?) {
        self.init(
            sender: sender, agentID: summary?.agentID, agentName: summary?.agentName, title: summary?.title,
            folder: summary?.workingDirectory.path, inReplyTo: inReplyTo)
    }

    /// The facts as lines of the prompt, one fact on each line: the agent,
    /// the agent name, the title, the folder and the answered message, in
    /// that order. A fact that is `nil` has no line.
    ///
    /// The sender chooses its title, and it can choose a folder or an agent
    /// name too, so each text value is quoted (``quoted(_:)``): no value can
    /// end its line and speak outside the fence.
    var factLines: [String] {
        let facts: [(label: String, value: String?)] = [
            ("agent", agentID.map(Self.quoted)),
            ("agent name", agentName.map(Self.quoted)),
            ("title", title.map(Self.quoted)),
            ("folder", folder.map(Self.quoted)),
            ("in reply to", inReplyTo?.value.ulidString),
        ]
        return facts.compactMap { fact in fact.value.map { "\(fact.label): \($0)" } }
    }

    /// `value` in double quotes, on one line: a double quote and a backslash
    /// get a backslash before them, and each character that breaks a line
    /// becomes `\u{<hex>}`, as in a Swift string literal.
    ///
    /// JSON text is not enough here: a JSON encoder keeps the line separator
    /// and the paragraph separator as they are.
    ///
    /// - Parameter value: A fact of the sender.
    /// - Returns: The quoted value.
    static func quoted(_ value: String) -> String {
        "\"" + value.unicodeScalars.map(escaped).joined() + "\""
    }

    /// One character of a quoted value (``quoted(_:)``).
    ///
    /// - Parameter scalar: A character of the value.
    /// - Returns: The character, or its escape.
    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        if scalar == "\"" || scalar == "\\" {
            return "\\\(scalar)"
        }
        guard lineBreakingCategories.contains(scalar.properties.generalCategory) else {
            return String(scalar)
        }
        return "\\u{\(String(scalar.value, radix: escapeRadix))}"
    }
}

/// The content of an agent message as the session directory writes it: the
/// header of the sender on the first line, then the text of the sender.
///
/// The header line is ``headerMarker`` and the header as one line of JSON.
/// The directory writes the header first for each message from a session,
/// so a header that the sender forges in its text is never the first line:
/// it stays in the text, which the renderer fences as untrusted input.
struct AgentMessageContent: Sendable, Equatable {
    /// The text before the JSON of the header on the first line.
    static let headerMarker = "[sender facts] "

    /// The line break between the header line and the text.
    private static let lineBreak: Character = "\n"

    /// The header that the directory wrote, or `nil` for content with no
    /// header that the renderer can trust.
    let header: AgentMessageHeader?

    /// The text of the sender.
    let text: String

    /// Makes the content of a message.
    ///
    /// - Parameters:
    ///   - header: The header of the sender, or `nil`.
    ///   - text: The text of the sender.
    init(header: AgentMessageHeader?, text: String) {
        self.header = header
        self.text = text
    }

    /// Reads the content of an agent message from `sender`.
    ///
    /// The first line is the header only when it is ``headerMarker`` and the
    /// JSON of a header that names `sender`. Then the text is what follows
    /// the first line break. Else the content has no header, and the whole
    /// content is the text.
    ///
    /// - Parameters:
    ///   - content: The content of the mail body.
    ///   - sender: The sender of the mail body.
    init(parsing content: String, from sender: ULID) {
        guard let split = content.firstIndex(of: Self.lineBreak),
            let header = Self.header(in: content[..<split]), header.sender == sender
        else {
            self.init(header: nil, text: content)
            return
        }
        self.init(header: header, text: String(content[content.index(after: split)...]))
    }

    /// The content as the mail body carries it: the header line, a line
    /// break and the text, or only the text when there is no header.
    var encoded: String {
        guard let header else { return text }
        guard let line = Self.headerLine(of: header) else {
            assertionFailure("the header of an agent message did not encode")
            RouterTelemetry.makeLogger(.mailDelivery).error(
                "the header of an agent message did not encode; the message goes with no header",
                metadata: [RouterTelemetry.LogMetadataKey.encodeContext: "agent message header"])
            return text
        }
        return line + String(Self.lineBreak) + text
    }

    /// The header line of `header`: ``headerMarker`` and the header as one
    /// line of JSON.
    ///
    /// - Parameter header: The header.
    /// - Returns: The line, or `nil` when the header does not encode.
    private static func headerLine(of header: AgentMessageHeader) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(header), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return headerMarker + json
    }

    /// The header of a first line, when the line is a header line.
    ///
    /// - Parameter line: The first line of a content.
    /// - Returns: The header, or `nil` when the line is not ``headerMarker``
    ///   and the JSON of a header.
    private static func header(in line: Substring) -> AgentMessageHeader? {
        guard line.hasPrefix(headerMarker) else { return nil }
        return try? JSONDecoder().decode(AgentMessageHeader.self, from: Data(line.dropFirst(headerMarker.count).utf8))
    }
}
