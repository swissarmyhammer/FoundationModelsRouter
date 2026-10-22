import Foundation
import Logging

/// The one line-decoding path every `transcript.jsonl` reader in this module
/// (``TranscriptTree`` and ``MergedTranscript``) shares, so the two readers
/// cannot drift: both drop the torn final line ``JSONLRecorder``'s durability
/// policy expects, and both fail loudly on corruption anywhere before it. The
/// `messages.jsonl` of a session (``SessionMessageLedger``) is appended the
/// same way, and reads through the same path
/// (``decodeLines(of:at:tornLineMessage:corruptLineError:)``).
enum TranscriptLineDecoding {
    /// One raw line of a `transcript.jsonl`: its byte offset within the file
    /// and its bytes, without the terminating newline.
    private struct Line {
        let byteOffset: Int
        let bytes: Data
    }

    /// Decodes every line of the `transcript.jsonl` at `fileURL`.
    ///
    /// The FINAL line is allowed to be torn: ``JSONLRecorder``'s durability
    /// policy syncs at submission close, so a crash mid-append tears at most the
    /// file's last line, and that torn tail is the expected crash artifact.
    /// A final line that fails to decode is therefore dropped, with a warning
    /// naming the file and the line's byte offset. A line that fails to
    /// decode anywhere BEFORE the final one is damage no policy expects, and
    /// throws.
    ///
    /// - Parameters:
    ///   - fileURL: The transcript file to read. Must exist.
    ///   - corruptLineError: Builds the error thrown when a line before the
    ///     file's last fails to decode — each reader names the corruption in
    ///     its own error vocabulary.
    /// - Returns: The decoded events, in file order.
    /// - Throws: The error `corruptLineError` builds when a line before the
    ///   file's last fails to decode; otherwise if the file cannot be read.
    static func decodeEvents(
        at fileURL: URL,
        corruptLineError: (URL) -> Error
    ) throws -> [TranscriptEvent] {
        try decodeLines(
            of: TranscriptEvent.self, at: fileURL,
            tornLineMessage: "dropping the torn final line of a transcript file",
            corruptLineError: corruptLineError)
    }

    /// Decodes every line of the JSONL file at `fileURL` as one `Record`, by
    /// the rule of ``decodeEvents(at:corruptLineError:)``: a final line that
    /// fails to decode is a torn append, dropped with the warning
    /// `tornLineMessage`; a line before it that fails to decode throws.
    ///
    /// - Parameters:
    ///   - type: The type of each line.
    ///   - fileURL: The file to read. Must exist.
    ///   - tornLineMessage: The constant log message of a dropped final line.
    ///   - corruptLineError: Builds the error thrown when a line before the
    ///     file's last fails to decode.
    /// - Returns: The decoded records, in file order.
    /// - Throws: The error `corruptLineError` builds when a line before the
    ///   file's last fails to decode; otherwise if the file cannot be read.
    static func decodeLines<Record: Decodable>(
        of type: Record.Type,
        at fileURL: URL,
        tornLineMessage: Logger.Message,
        corruptLineError: (URL) -> Error
    ) throws -> [Record] {
        let lines = nonEmptyLines(in: try Data(contentsOf: fileURL))
        let decoder = JSONDecoder()
        var records: [Record] = []
        for (index, line) in lines.enumerated() {
            do {
                records.append(try decoder.decode(type, from: line.bytes))
            } catch {
                guard index == lines.indices.last else {
                    throw corruptLineError(fileURL)
                }
                RouterTelemetry.makeLogger(.transcriptLineDecoding).warning(
                    tornLineMessage,
                    metadata: RouterTelemetry.errorMetadata(error).merging([
                        RouterTelemetry.LogMetadataKey.filePath: "\(fileURL.path)",
                        RouterTelemetry.LogMetadataKey.byteOffset: "\(line.byteOffset)",
                    ]) { _, new in new })
            }
        }
        return records
    }

    /// Splits `data` into its non-empty lines, keeping each line's byte
    /// offset so a torn final line can be reported by position.
    ///
    /// - Parameter data: A whole `transcript.jsonl`'s bytes.
    /// - Returns: Each non-empty line, in file order.
    private static func nonEmptyLines(in data: Data) -> [Line] {
        var lines: [Line] = []
        var lineStart = data.startIndex
        for index in data.indices where data[index] == jsonlNewlineByte {
            if index > lineStart {
                lines.append(
                    Line(byteOffset: lineStart - data.startIndex, bytes: data[lineStart..<index])
                )
            }
            lineStart = data.index(after: index)
        }
        if lineStart < data.endIndex {
            lines.append(
                Line(byteOffset: lineStart - data.startIndex, bytes: data[lineStart...])
            )
        }
        return lines
    }
}
