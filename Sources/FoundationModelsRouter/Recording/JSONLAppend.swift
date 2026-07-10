import Foundation
import os

/// A failure validating or opening a JSONL sink's append target.
public enum JSONLAppendError: Error, Equatable, LocalizedError {
    /// `fileName` is not a plain, single-component file name — it contains a
    /// path separator (`/`) or is a navigation token (`.` or `..`) that would
    /// let the append land outside the intended directory.
    case invalidFileName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName(let fileName):
            return
                "\"\(fileName)\" is not a valid JSONL file name: it must be a single path component, with no \"/\" and not \".\" or \"..\"."
        }
    }
}

/// Whether `fileName` is a plain single path component: non-empty, free of
/// path separators, and not a `.`/`..` navigation token that would resolve
/// outside `directory` when appended.
private func isPlainFileName(_ fileName: String) -> Bool {
    !fileName.isEmpty && !fileName.contains("/") && fileName != "." && fileName != ".."
}

/// The on-disk append lifecycle shared by every JSONL sink in this module
/// (``JSONLRecorder``, ``SessionIndexWriter``): create the directory and file
/// on first use, open a handle, and seek to its end. Callers own their own
/// handle-caching strategy — this always creates and opens a fresh handle.
///
/// - Parameters:
///   - fileName: The file's name within `directory` (e.g. `"transcript.jsonl"`).
///     Must be a plain single path component — validated before use so a
///     future caller can never widen this shared helper into a directory
///     escape.
///   - directory: The directory the file lives in, created if missing.
/// - Returns: A handle positioned at the end of the file.
/// - Throws: ``JSONLAppendError/invalidFileName(_:)`` if `fileName` contains a
///   path separator or is a `.`/`..` navigation token; otherwise if the
///   directory or file cannot be created or opened.
func openHandleForAppending(fileName: String, in directory: URL) throws -> FileHandle {
    guard isPlainFileName(fileName) else {
        throw JSONLAppendError.invalidFileName(fileName)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    return handle
}

/// Encodes `value` as one compact JSON line and appends it via a handle
/// obtained from `handle`, logging and dropping it on any failure — the
/// best-effort append shape shared by every JSONL sink in this module
/// (``JSONLRecorder``, ``SessionIndexWriter``). Never throws: a failure
/// obtaining the handle, encoding `value`, or writing the line is reported to
/// `logger` and the value is dropped rather than surfaced to the caller.
///
/// - Parameters:
///   - value: The value to encode and append.
///   - encoder: The encoder `value` is serialized with.
///   - logger: The logger a dropped value is reported to.
///   - handle: Produces (creating and/or caching as the caller sees fit) the
///     handle to append to.
///   - describeFailure: Builds the log message for a caught error.
func appendJSONLine<Value: Encodable>(
    _ value: Value,
    encoder: JSONEncoder,
    logger: Logger,
    handle: () throws -> FileHandle,
    describeFailure: (Error) -> String
) {
    do {
        let handle = try handle()
        var line = try encoder.encode(value)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    } catch {
        let message = describeFailure(error)
        logger.error("\(message, privacy: .public)")
    }
}
