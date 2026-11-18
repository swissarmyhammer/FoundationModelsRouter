import Foundation
import FoundationModelsExtras

/// The header line that the session directory writes before the text of a
/// message from the user that names its source session (D199 (f)).
///
/// The message stays a user message
/// (``MailBody/userMessage(prompt:options:)``), so the header is plain text
/// at the start of the prompt, with no notice: the message is an
/// instruction from the user. The words are the same as the words of the
/// in-memory directory of FoundationModelsExtras:
///
/// - A source session that the directory knows:
///   `From the user, in <title> (<folder>)`. `<title>` is the title of the
///   session, or its short id when the title is missing or empty.
///   `<folder>` is the path of its working folder.
/// - A source session that the directory does not know:
///   `From the user, in the session <id>`.
///
/// A blank line separates the header line from the text of the message.
struct UserMessageHeader: Sendable, Equatable {
    /// The text between the header line and the text of the message.
    private static let separator = "\n\n"

    /// The header line.
    let line: String

    /// Makes the header of a message that the user wrote in the session
    /// `source`.
    ///
    /// - Parameters:
    ///   - source: The source session of the message.
    ///   - summary: The live or recorded summary of `source`, or `nil` when
    ///     the directory does not know the session. The header then names
    ///     only the session id.
    init(source: ULID, summary: SessionSummary?) {
        guard let summary else {
            line = "From the user, in the session \(source.ulidString)"
            return
        }
        line = "From the user, in \(Self.name(of: summary)) (\(summary.workingDirectory.path))"
    }

    /// Makes the header of a header line that a send made before. The inbox
    /// file of a recorded session keeps the line
    /// (``SessionInboxMessage/userHeader``), and the scan of the inbox gives
    /// it back here.
    ///
    /// - Parameter line: The header line.
    init(line: String) {
        self.line = line
    }

    /// The prompt of the message: the header line, a blank line and `text`.
    ///
    /// - Parameter text: The text of the message.
    /// - Returns: The prompt.
    func prompt(with text: String) -> String {
        line + Self.separator + text
    }

    /// The title of the session, or its short id when the title is missing
    /// or empty.
    ///
    /// - Parameter summary: The summary of the session.
    /// - Returns: The name that the header shows.
    private static func name(of summary: SessionSummary) -> String {
        guard let title = summary.title, !title.isEmpty else { return summary.shortID }
        return title
    }
}
