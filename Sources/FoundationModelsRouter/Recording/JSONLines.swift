import Foundation
import FoundationModelsExtras

/// The JSON coders of a session's `facts.json` (``SessionFacts``): RFC 3339
/// dates in UTC with milliseconds, for example `2026-10-22T10:58:03.123Z`, and
/// keys in sorted order, so a record's bytes are stable across writes. The
/// date text is the text of the Extras `DateTime`, which the line coders of
/// the Extras `JSONLFile` write and read for every JSONL file of this module
/// (``JSONLAppend``), so every date on disk has one form.
enum JSONLines {
    /// The description of the error of a date that is not the text the
    /// encoder writes.
    private static let notMillisecondTextDescription =
        "The date is not RFC 3339 text in UTC with milliseconds."

    /// The encoder every record is written with: RFC 3339 dates in UTC with
    /// milliseconds, each date rounded to the nearest millisecond, and sorted
    /// keys, on one line.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try DateTime(date).encode(to: encoder)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The decoder every record is read with: RFC 3339 dates in UTC with
    /// milliseconds, the text the encoder writes. A date in any other text,
    /// one with whole seconds only among them, throws
    /// `DecodingError.dataCorrupted`.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate)
        return decoder
    }

    /// Decodes one date from the text the encoder writes.
    ///
    /// The parser of `DateTime` also takes text with whole seconds only, so
    /// the text must also be the exact text the date writes back.
    ///
    /// - Parameter decoder: The decoder that holds the text.
    /// - Returns: The date of the text.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not RFC 3339
    ///   in UTC with milliseconds, or the error of the decoder when the value
    ///   is not a string.
    private static func decodeDate(from decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let time = try? DateTime(rfc3339: text), time.rfc3339 == text else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: notMillisecondTextDescription)
        }
        return time.date
    }
}
