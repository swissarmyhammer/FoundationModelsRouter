import Foundation
import FoundationModelsExtras

/// The one form of every date Router writes to disk: ISO 8601 text in UTC
/// with milliseconds, for example `2026-10-22T10:58:03.123Z`, the text of the
/// Extras `DateTime`. The JSON lines (``JSONLines``) and the frontmatter of a
/// session's `index.md` (``SessionRecord``) both read and write it.
enum MillisecondDate {
    /// The description of the error of a date that is not the text Router
    /// writes.
    static let notMillisecondTextDescription = "The date is not RFC 3339 text in UTC with milliseconds."

    /// `date` at the precision of the text: rounded to the nearest
    /// millisecond, so a value stored with it reads back equal.
    ///
    /// - Parameter date: An instant.
    /// - Returns: The rounded instant.
    static func rounded(_ date: Date) -> Date {
        DateTime(date).date
    }

    /// The text of `date`.
    ///
    /// - Parameter date: An instant.
    /// - Returns: The ISO 8601 text in UTC with milliseconds.
    static func text(of date: Date) -> String {
        DateTime(date).rfc3339
    }

    /// The date of `text`, when `text` is exactly the text that ``text(of:)``
    /// writes. The parser of `DateTime` also takes text with whole seconds
    /// only, so the text must also be the exact text that the date writes
    /// back.
    ///
    /// - Parameter text: The text of a date.
    /// - Returns: The date, or `nil` when the text is another form.
    static func date(fromText text: String) -> Date? {
        guard let time = try? DateTime(rfc3339: text), time.rfc3339 == text else { return nil }
        return time.date
    }
}
