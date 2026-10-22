import Foundation
import FoundationModelsExtras

@testable import FoundationModelsRouter

/// JSON coders for the tests that write or read one transcript line by hand:
/// RFC 3339 dates in UTC with milliseconds, for example
/// `2026-10-22T10:58:03.123Z` (``MillisecondDate``), the text the line coders
/// of the Extras `JSONLFile` write and read for every JSONL file of Router,
/// and keys in sorted order, so a line's bytes are stable across writes.
enum JSONLines {
    /// The encoder a test line is written with: RFC 3339 dates in UTC with
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

    /// The decoder a test line is read with: RFC 3339 dates in UTC with
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
    /// - Parameter decoder: The decoder that holds the text.
    /// - Returns: The date of the text.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not RFC 3339
    ///   in UTC with milliseconds, or the error of the decoder when the value
    ///   is not a string.
    private static func decodeDate(from decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        guard let date = MillisecondDate.date(fromText: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: MillisecondDate.notMillisecondTextDescription)
        }
        return date
    }
}
