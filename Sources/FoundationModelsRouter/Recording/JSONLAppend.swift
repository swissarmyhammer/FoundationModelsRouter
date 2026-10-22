import Foundation
import FoundationModelsExtras
import Logging

/// The append of one record as one line at the end of a JSONL file.
///
/// ``JSONLAppend/toDisk`` is the production append. A test passes a spy in
/// its place to see each append without disk I/O.
///
/// - Parameters:
///   - record: The record to append.
///   - file: The JSONL file.
/// - Throws: The error of the append.
typealias JSONLLineAppend = @Sendable (_ record: any Encodable, _ file: URL) throws -> Void

/// The one way this module appends to a JSONL file — `transcript.jsonl`
/// (``JSONLRecorder``) and `messages.jsonl` (``SessionMessageLedger``): the
/// Extras `JSONLFile`. The file is append only. Each append is one whole line
/// in one write, opened with `O_APPEND`, healed when the file ends with a torn
/// line, and flushed with `fsync(2)` before it returns.
enum JSONLAppend {
    /// Appends a record through `JSONLFile`, after it creates the folder of
    /// the file when the folder is absent.
    static let toDisk: JSONLLineAppend = { record, file in
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONLFile(url: file).append(record)
    }

    /// Appends `record` through `append`, and logs and drops a failure: the
    /// best-effort append of the transcript and of the message ledger. It
    /// never throws.
    ///
    /// - Parameters:
    ///   - record: The record to append.
    ///   - file: The JSONL file.
    ///   - append: The line append. The default is ``toDisk``.
    ///   - logger: The logger a dropped record is reported to.
    ///   - failureMessage: The constant log message for a caught error.
    ///   - failureMetadata: The log metadata of the record, for example its
    ///     sequence number. The log record also holds the type and the code of
    ///     the error (``RouterTelemetry/errorMetadata(_:)``), and never its
    ///     description.
    static func appendDroppingFailure(
        _ record: some Encodable,
        to file: URL,
        through append: JSONLLineAppend = toDisk,
        logger: Logger,
        failureMessage: Logger.Message,
        failureMetadata: Logger.Metadata
    ) {
        do {
            try append(record, file)
        } catch {
            logger.error(
                failureMessage,
                metadata: RouterTelemetry.errorMetadata(error).merging(failureMetadata) { _, new in new })
        }
    }
}
