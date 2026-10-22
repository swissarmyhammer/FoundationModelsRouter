import Foundation
import FoundationModelsExtras
import Logging

/// A failure to read the `index.md` of a session folder.
public enum SessionIndexFileError: Error, Equatable, LocalizedError {
    /// `file` holds no YAML frontmatter, so it holds no session record.
    case missingFrontmatter(file: URL)

    /// The frontmatter of `file` does not decode as a ``SessionRecord``.
    case undecodable(file: URL, description: String)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .missingFrontmatter(let file):
            return "Session index \(file.path) has no frontmatter, so it holds no session record."
        case .undecodable(let file, let description):
            return "The frontmatter of session index \(file.path) does not decode as a session record: \(description)"
        }
    }
}

/// The `index.md` of one session folder: its ``SessionRecord`` as YAML
/// frontmatter, and an open body below it.
///
/// Router never reads the body, and each save keeps it byte for byte: the
/// save reads the body of the file on disk and writes it back below the new
/// frontmatter. A save goes through the Extras `FrontmatterDocument` save,
/// which writes a temporary file, flushes it to the disk and swaps it into
/// place with one rename, so a reader sees the old file or the new file,
/// never a part.
enum SessionIndexFile {
    /// The name of the file in a session folder.
    static let fileName = "index.md"

    /// The `index.md` of a session folder.
    ///
    /// - Parameter directory: The session folder.
    /// - Returns: The file URL.
    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Reads the record in a session folder.
    ///
    /// - Parameter directory: The session folder.
    /// - Returns: The record, or `nil` when the folder holds no `index.md`.
    /// - Throws: ``SessionIndexFileError`` when the file holds no frontmatter
    ///   or the frontmatter does not decode,
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when the record carries a schema version newer than
    ///   ``RecordingSchemaVersion/current``, or the error of the read.
    static func read(in directory: URL) throws -> SessionRecord? {
        let file = url(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let frontmatter = FrontmatterDocument.split(text: try String(contentsOf: file, encoding: .utf8))
            .frontmatter
        else {
            throw SessionIndexFileError.missingFrontmatter(file: file)
        }
        let record = try decodeRecord(from: frontmatter, of: file)
        guard record.schemaVersion <= RecordingSchemaVersion.current else {
            throw RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: directory, version: record.schemaVersion, supported: RecordingSchemaVersion.current)
        }
        return record
    }

    /// Saves `record` as the frontmatter of the `index.md` of a session
    /// folder, and keeps the body of the file that is there.
    ///
    /// - Parameters:
    ///   - record: The record.
    ///   - directory: The session folder. It must exist.
    /// - Throws: The error of the read of the body, or
    ///   `FrontmatterDocumentSaveError` when the save fails; the file on
    ///   disk stays as it was.
    static func save(_ record: SessionRecord, in directory: URL) throws {
        let file = url(in: directory)
        try FrontmatterDocument(metadata: record, content: try body(of: file)).save(to: file)
    }

    /// Saves `record` as ``save(_:in:)`` does, and logs a failure instead of
    /// throwing it: the save is best effort, and the session goes on.
    ///
    /// - Parameters:
    ///   - record: The record.
    ///   - directory: The session folder. It must exist.
    static func saveLoggingFailure(_ record: SessionRecord, in directory: URL) {
        do {
            try save(record, in: directory)
        } catch {
            logDroppedSave(error: error, directory: directory)
        }
    }

    /// Logs a save of an `index.md` that failed and was dropped: the type and
    /// the code of `error`, and the path of `directory`.
    ///
    /// - Parameters:
    ///   - error: The error of the save.
    ///   - directory: The session folder.
    static func logDroppedSave(error: any Error, directory: URL) {
        RouterTelemetry.makeLogger(.sessionIndex).error(
            "dropping a save of a session index.md",
            metadata: RouterTelemetry.errorMetadata(error).merging([
                RouterTelemetry.LogMetadataKey.filePath: "\(directory.path)"
            ]) { _, new in new })
    }

    /// The body of `file`: the text after its frontmatter, the whole text
    /// when it has no frontmatter, or no text when there is no file.
    ///
    /// - Parameter file: The `index.md` of a session folder.
    /// - Returns: The body.
    /// - Throws: The error of the read of a file that is there.
    private static func body(of file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return FrontmatterDocument.split(text: try String(contentsOf: file, encoding: .utf8)).body
    }

    /// Decodes the record of a frontmatter.
    ///
    /// - Parameters:
    ///   - frontmatter: The YAML text of the frontmatter.
    ///   - file: The `index.md` the frontmatter is from, for the error.
    /// - Returns: The record.
    /// - Throws: ``SessionIndexFileError/undecodable(file:description:)``
    ///   when the YAML does not parse or does not decode as a record.
    private static func decodeRecord(from frontmatter: String, of file: URL) throws -> SessionRecord {
        do {
            return try YAMLValue.parse(frontmatter).decoded(as: SessionRecord.self)
        } catch {
            throw SessionIndexFileError.undecodable(file: file, description: String(describing: error))
        }
    }
}
