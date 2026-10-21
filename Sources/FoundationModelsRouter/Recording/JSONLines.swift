import Foundation

/// Shared plumbing for the JSON-lines files of the record of past sessions:
/// `sessions.jsonl` (``SessionIndex``) and `projects.jsonl`
/// (``ProjectRegistry``). One record per line, RFC 3339 dates, keys in sorted
/// order so a record's line is stable across writes.
///
/// The bytes are the bytes the ACPAgent `Transcripts/JSONLines` helper wrote
/// before Router owned the record (D72), so a file on a user's disk stays
/// valid. ``appendJSONLine(_:encoder:logger:handle:failureMessage:failureMetadata:)``
/// does not serve here: it logs and drops a failure, and the index and the
/// registry throw.
enum JSONLines {
    /// The encoder every record line is written with: RFC 3339 dates and
    /// sorted keys, on one line.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The decoder every record line is read with: RFC 3339 dates.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `record` as one newline-terminated line.
    ///
    /// - Parameter record: The record to encode.
    /// - Returns: The encoded line, with ``jsonlNewlineByte`` at its end.
    /// - Throws: The encoder's error when `record` cannot be encoded.
    static func encodedLine(of record: some Encodable) throws -> Data {
        var line = try makeEncoder().encode(record)
        line.append(jsonlNewlineByte)
        return line
    }

    /// Replaces `file` with one line for each of `records`, in order, written
    /// atomically. The parent directory must already exist.
    ///
    /// - Parameters:
    ///   - records: The records the file holds afterwards.
    ///   - file: The file to replace.
    /// - Throws: An encode error, or a file-system error when the write
    ///   fails.
    static func replaceFile(_ file: URL, withLinesOf records: [some Encodable]) throws {
        let contents = try records.reduce(into: Data()) { contents, record in
            contents.append(try encodedLine(of: record))
        }
        try contents.write(to: file, options: .atomic)
    }

    /// Appends `line` to `file`, creating the file when it is absent. The
    /// parent directory must already exist.
    ///
    /// - Parameters:
    ///   - line: The encoded line to append.
    ///   - file: The file to append to.
    /// - Throws: A file-system error when the file cannot be written.
    static func appendLine(_ line: Data, to file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            try line.write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Best-effort close on the failure path; the write error is the
            // one the caller must see.
            try? handle.close()
            throw error
        }
        try handle.close()
    }
}
