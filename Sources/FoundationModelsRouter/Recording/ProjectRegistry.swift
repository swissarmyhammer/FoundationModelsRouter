import Foundation
import FoundationModelsExtras

/// One line of `projects.jsonl`: a project the user worked
/// in. Paths only, never content.
public struct ProjectRegistryRecord: Codable, Equatable, Sendable {
    /// The absolute path of the project's working directory.
    public var path: String

    /// The instant of the first session in this directory.
    public var firstSeen: Date

    /// The instant of the most recent session in this directory.
    public var lastSeen: Date

    /// Makes a record from its three fields.
    ///
    /// - Parameters:
    ///   - path: The absolute working directory path.
    ///   - firstSeen: The first session's instant.
    ///   - lastSeen: The most recent session's instant.
    public init(path: String, firstSeen: Date, lastSeen: Date) {
        self.path = path
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

extension ProjectRegistryRecord: JSONLKeyedRecord {
    /// The key of the record: its path. The newest line of a path wins.
    public var key: String { path }

    /// A registry record never removes its path.
    public var isTombstone: Bool { false }
}

/// The cross-project registry in the user layer:
/// `~/.config/<name>/projects.jsonl`. The cross-project session browser
/// reads it to answer "what did I do in repo X last week?". It is a cache,
/// not a record: the user can delete it, and a stale entry is skipped on
/// read.
///
/// The file is append only and goes through the Extras `JSONLFile`
/// (``JSONLAppend``): a session start appends one line for its path, and the
/// newest line of a path wins on read. A line that does not decode is
/// skipped with a warning.
public struct ProjectRegistry: Sendable {
    /// The registry file's name inside the user layer.
    public static let registryFileName = "projects.jsonl"

    /// The user layer root the registry file lives in,
    /// `~/.config/<name>/` in production; tests inject a value so they
    /// never touch the real home directory.
    public let directory: URL

    /// Makes the registry of the user layer at `directory`.
    ///
    /// - Parameter directory: The user layer root.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The registry file's URL.
    private var registryFile: URL {
        directory.appendingPathComponent(Self.registryFileName)
    }

    /// Records a session start: appends one line for the working directory,
    /// with `lastSeen` at `date` and the `firstSeen` of its earlier line, or
    /// `date` for a new working directory.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session's absolute working directory.
    ///   - date: The session's start instant.
    /// - Throws: A file-system error when the user layer cannot be created,
    ///   or the `JSONLFileError` of a read or an append that fails.
    public func recordSessionStart(workingDirectory: URL, at date: Date = Date()) throws {
        let path = workingDirectory.standardizedFileURL.path
        let firstSeen = try storedRecords().first { $0.path == path }?.firstSeen ?? date
        try JSONLAppend.toDisk(
            ProjectRegistryRecord(path: path, firstSeen: firstSeen, lastSeen: date), registryFile)
    }

    /// The live records: each stored record whose path is still a
    /// directory. A stale entry — a project that was moved or deleted —
    /// is skipped, not an error.
    ///
    /// - Returns: The live records, in the order of the first line of each
    ///   path.
    /// - Throws: `JSONLFileError.readFailed(description:)` when an existing
    ///   registry file cannot be read.
    public func projects() throws -> [ProjectRegistryRecord] {
        try storedRecords().filter { record in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: record.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    /// The newest record of each path, in the order of the first line of
    /// each path. A missing file gives none.
    ///
    /// - Returns: The newest record of each path.
    /// - Throws: `JSONLFileError.readFailed(description:)` when an existing
    ///   registry file cannot be read.
    private func storedRecords() throws -> [ProjectRegistryRecord] {
        let lines = try JSONLFile(url: registryFile).records(as: ProjectRegistryRecord.self)
        let firstLine = Dictionary(
            lines.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: min)
        return JSONLFile.fold(lines).values.sorted {
            firstLine[$0.path, default: 0] < firstLine[$1.path, default: 0]
        }
    }
}
