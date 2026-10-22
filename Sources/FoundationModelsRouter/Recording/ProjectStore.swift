import Foundation
import FoundationModelsExtras
import Logging

/// One project a user worked in: the frontmatter of its project file in a
/// ``ProjectStore``. Paths only, never content.
///
/// Each date is ISO 8601 text in UTC with milliseconds (the text of the
/// Extras `DateTime`), as every other date Router writes to disk. A date is
/// rounded to the millisecond when the record is made, so a record reads back
/// equal to the one that was saved.
public struct ProjectRecord: Codable, Equatable, Sendable {
    /// The standardized absolute path of the project's working directory.
    public var path: String

    /// The instant of the first session in this directory.
    public var firstSeen: Date

    /// The instant of the most recent session in this directory.
    public var lastSeen: Date

    /// Makes a record from its three fields. Each date is stored rounded to
    /// the millisecond, the precision of the frontmatter.
    ///
    /// - Parameters:
    ///   - path: The absolute working directory path.
    ///   - firstSeen: The first session's instant.
    ///   - lastSeen: The most recent session's instant.
    public init(path: String, firstSeen: Date, lastSeen: Date) {
        self.path = path
        self.firstSeen = MillisecondDate.rounded(firstSeen)
        self.lastSeen = MillisecondDate.rounded(lastSeen)
    }

    /// The keys of the frontmatter.
    private enum CodingKeys: String, CodingKey {
        case path, firstSeen, lastSeen
    }

    /// Decodes a record from its frontmatter.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when a key is absent, a key holds the wrong
    ///   type, or a date is not ISO 8601 text in UTC with milliseconds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        firstSeen = try container.decodeMillisecondDate(forKey: .firstSeen)
        lastSeen = try container.decodeMillisecondDate(forKey: .lastSeen)
    }

    /// Encodes the record as its frontmatter, each date as text with
    /// milliseconds.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(MillisecondDate.text(of: firstSeen), forKey: .firstSeen)
        try container.encode(MillisecondDate.text(of: lastSeen), forKey: .lastSeen)
    }
}

/// The projects of a user: a folder the host gives, with one markdown file
/// for each project. The cross-project session browser reads it to answer
/// "what did I do in repo X last week?". Router never picks the folder: a
/// host can keep it in a folder that syncs, such as an iCloud folder.
///
/// The file of a project is named `<sha256 of its standardized path, in
/// lowercase hex>.md`, and its YAML frontmatter holds the ``ProjectRecord``.
/// One file per project lets several devices write the folder at once
/// without a conflict: a register rewrites only the file of its own project,
/// and a remove deletes only that file. A save goes through the Extras
/// `FrontmatterDocument` save, which writes a temporary file, flushes it to
/// the disk and swaps it into place with one rename, and it keeps the body a
/// host wrote below the frontmatter.
///
/// A listing reads each `.md` file of the folder and ignores every other
/// file. It skips, with a warning, each file it cannot read as the record of
/// its own name, such as a partial download or a sync conflict copy, and it
/// never fails for one such file.
public struct ProjectStore: Sendable {
    /// The extension of a project file.
    private static let fileExtension = "md"

    /// The message of the `warning` record of a listing that skips a file.
    private static let skippedFileMessage: Logger.Message =
        "skipped a project file that does not hold a project record"

    /// The message of the `warning` record of a register that replaces a
    /// file it cannot read.
    private static let replacedFileMessage: Logger.Message =
        "replacing a project file that does not hold a project record"

    /// The folder of the project files, which the host gives.
    public let directory: URL

    /// Makes the store of the project files in `directory`. The folder need
    /// not exist: the first register creates it.
    ///
    /// - Parameter directory: The folder of the project files.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The name of the file of the project at `workingDirectory`: the
    /// lowercase hex SHA-256 of its standardized path, then `.md`. Every
    /// spelling of one path gives the same name.
    ///
    /// - Parameter workingDirectory: The project's working directory.
    /// - Returns: The file name.
    public static func fileName(forWorkingDirectory workingDirectory: URL) -> String {
        fileName(forPath: standardizedPath(of: workingDirectory))
    }

    /// Records a session start in the project at `workingDirectory`: writes
    /// its file with `lastSeen` at `date`, and `firstSeen` from the file that
    /// is there, or `date` for a new project. A file that is there and cannot
    /// be read as the project's record is replaced, with a warning.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session's absolute working directory.
    ///   - date: The session's start instant.
    /// - Throws: A file-system error when the folder cannot be created, or
    ///   `FrontmatterDocumentSaveError` when the save fails; the file on disk
    ///   stays as it was.
    public func register(workingDirectory: URL, at date: Date = Date()) throws {
        let path = Self.standardizedPath(of: workingDirectory)
        let file = fileURL(forPath: path)
        let stored = storedDocumentReplacingFailure(at: file)
        let record = ProjectRecord(path: path, firstSeen: stored?.record.firstSeen ?? date, lastSeen: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FrontmatterDocument(metadata: record, content: stored?.body ?? "").save(to: file)
    }

    /// Removes the project at `workingDirectory`: deletes its file. A project
    /// the store does not hold is no error.
    ///
    /// - Parameter workingDirectory: The project's working directory.
    /// - Throws: The file-system error of a delete that fails for a reason
    ///   other than a missing file.
    public func remove(workingDirectory: URL) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(forPath: Self.standardizedPath(of: workingDirectory)))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// The live projects: the record of each project file whose path is
    /// still a directory, the earliest `firstSeen` first. A stale project —
    /// one that was moved or deleted — is skipped, not an error, and so is
    /// each file a listing cannot read, with a warning.
    ///
    /// - Returns: The live records, ordered by `firstSeen`, then by path.
    /// - Throws: The file-system error of a listing of a folder that exists
    ///   and cannot be read. A folder that does not exist holds no projects.
    public func projects() throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return entries.filter(Self.isProjectFile)
            .compactMap(listedRecord(at:))
            .filter(Self.isLive)
            .sorted(by: Self.isListedBefore)
    }

    // MARK: - Files

    /// The standardized path of a working directory, the key of its project.
    ///
    /// - Parameter workingDirectory: The working directory.
    /// - Returns: The path with no `.` or `..` component and no trailing `/`.
    private static func standardizedPath(of workingDirectory: URL) -> String {
        workingDirectory.standardizedFileURL.path
    }

    /// The name of the file of the project at `path`.
    ///
    /// - Parameter path: The standardized path of the project.
    /// - Returns: The file name.
    private static func fileName(forPath path: String) -> String {
        "\(SHA256Hex.text(of: path)).\(fileExtension)"
    }

    /// The file of the project at `path` in ``directory``.
    ///
    /// - Parameter path: The standardized path of the project.
    /// - Returns: The file URL.
    private func fileURL(forPath path: String) -> URL {
        directory.appendingPathComponent(Self.fileName(forPath: path), isDirectory: false)
    }

    /// Whether `file` is a project file: its extension is `md`, in any case,
    /// as the file system of the host matches names.
    ///
    /// - Parameter file: An entry of the folder.
    /// - Returns: `true` for a `.md` file.
    private static func isProjectFile(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == fileExtension
    }

    /// Whether the path of `record` is still a directory.
    ///
    /// - Parameter record: A stored record.
    /// - Returns: `true` when the project's directory exists.
    private static func isLive(_ record: ProjectRecord) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// The order of a listing: the earliest `firstSeen` first, then by path.
    ///
    /// - Parameters:
    ///   - first: A record.
    ///   - second: Another record.
    /// - Returns: `true` when `first` comes before `second`.
    private static func isListedBefore(_ first: ProjectRecord, _ second: ProjectRecord) -> Bool {
        (first.firstSeen, first.path) < (second.firstSeen, second.path)
    }

    // MARK: - Reads

    /// The record of a project file, or `nil` with a warning when the file
    /// cannot be read as the record of its own name.
    ///
    /// - Parameter file: A `.md` file of the folder.
    /// - Returns: The record, or `nil`.
    private func listedRecord(at file: URL) -> ProjectRecord? {
        do {
            return try Self.storedDocument(at: file)?.record
        } catch {
            Self.logUnreadable(file, error: error, message: Self.skippedFileMessage)
            return nil
        }
    }

    /// The stored record and body of the file of a register, or `nil` when
    /// there is no file, or with a warning when the file cannot be read as
    /// the record of its own name.
    ///
    /// - Parameter file: The file of the project.
    /// - Returns: The record and the body, or `nil`.
    private func storedDocumentReplacingFailure(at file: URL) -> ProjectFile.Document? {
        do {
            return try Self.storedDocument(at: file)
        } catch {
            Self.logUnreadable(file, error: error, message: Self.replacedFileMessage)
            return nil
        }
    }

    /// Reads a project file: its record and the body below the frontmatter.
    ///
    /// - Parameter file: A project file.
    /// - Returns: The record and the body, or `nil` when there is no file.
    /// - Throws: ``ProjectFileError`` when the file holds no frontmatter, the
    ///   frontmatter does not decode, or the record's path does not give the
    ///   file's name; or the error of the read.
    private static func storedDocument(at file: URL) throws -> ProjectFile.Document? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let document = try ProjectFile.document(ofText: try String(contentsOf: file, encoding: .utf8))
        guard file.lastPathComponent.lowercased() == fileName(forPath: document.record.path) else {
            throw ProjectFileError.misnamed
        }
        return document
    }

    /// Logs a project file that a read skipped: the type and the code of the
    /// error, and the path of the file. The name of a project file is a hash,
    /// so the record never holds the path of a project.
    ///
    /// - Parameters:
    ///   - file: The project file.
    ///   - error: The error of the read.
    ///   - message: The message of the record.
    private static func logUnreadable(_ file: URL, error: any Error, message: Logger.Message) {
        RouterTelemetry.makeLogger(.projectStore).warning(
            message,
            metadata: RouterTelemetry.errorMetadata(error).merging([
                RouterTelemetry.LogMetadataKey.filePath: "\(file.path)"
            ]) { _, new in new })
    }
}

/// A project file that does not hold the record of its own name.
enum ProjectFileError: Error, Equatable {
    /// The file holds no YAML frontmatter, as a partial download does.
    case missingFrontmatter

    /// The frontmatter does not decode as a ``ProjectRecord``.
    case undecodable(description: String)

    /// The record's path does not give the name of the file, as a sync
    /// conflict copy such as `<hash> 2.md` does.
    case misnamed
}

/// The text of a project file: the ``ProjectRecord`` as YAML frontmatter,
/// and an open body below it.
enum ProjectFile {
    /// A read project file.
    struct Document {
        /// The record of the frontmatter.
        let record: ProjectRecord

        /// The text after the frontmatter, byte for byte.
        let body: String
    }

    /// Reads the text of a project file.
    ///
    /// - Parameter text: The text of the file.
    /// - Returns: The record and the body.
    /// - Throws: ``ProjectFileError/missingFrontmatter`` when the text holds
    ///   no frontmatter, or ``ProjectFileError/undecodable(description:)``
    ///   when the frontmatter does not decode as a record.
    static func document(ofText text: String) throws -> Document {
        let split = FrontmatterDocument.split(text: text)
        guard let frontmatter = split.frontmatter else { throw ProjectFileError.missingFrontmatter }
        do {
            return Document(record: try YAMLValue.parse(frontmatter).decoded(as: ProjectRecord.self), body: split.body)
        } catch {
            throw ProjectFileError.undecodable(description: String(describing: error))
        }
    }
}
