import Foundation

/// The JSON coders of a session's `facts.json` (``SessionFacts``): RFC 3339
/// dates and keys in sorted order, so a record's bytes are stable across
/// writes. They match the line coders of the Extras `JSONLFile`, which writes
/// and reads every JSONL file of this module (``JSONLAppend``).
enum JSONLines {
    /// The encoder every record is written with: RFC 3339 dates and sorted
    /// keys, on one line.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The decoder every record is read with: RFC 3339 dates.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
