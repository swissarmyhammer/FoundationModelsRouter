import Foundation
import Logging

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

/// The cross-project registry in the user layer:
/// `~/.config/<name>/projects.jsonl`. The cross-project session browser
/// reads it to answer "what did I do in repo X last week?". It is a cache,
/// not a record: the user can delete it, and a stale entry is skipped on
/// read.
///
/// Router owns the record of past sessions (D72). The file name and the line
/// format are the ones the ACP agent wrote before Router owned the record, so
/// the files on a user's disk stay valid.
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

    /// Records a session start: a new working directory
    /// appends one record, and a revisit updates that record's `lastSeen`
    /// in place — never a second line for the same path.
    ///
    /// - Parameters:
    ///   - workingDirectory: The session's absolute working directory.
    ///   - date: The session's start instant.
    /// - Throws: A file-system error when the registry cannot be written.
    public func recordSessionStart(workingDirectory: URL, at date: Date = Date()) throws {
        let path = workingDirectory.standardizedFileURL.path
        var records = try storedRecords()
        guard let index = records.firstIndex(where: { $0.path == path }) else {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let record = ProjectRegistryRecord(path: path, firstSeen: date, lastSeen: date)
            try JSONLines.appendLine(JSONLines.encodedLine(of: record), to: registryFile)
            return
        }
        records[index].lastSeen = date
        try write(records)
    }

    /// The live records: each stored record whose path is still a
    /// directory. A stale entry — a project that was moved or deleted —
    /// is skipped, not an error.
    ///
    /// - Returns: The live records, in file order.
    /// - Throws: A file-system error when an existing registry file cannot
    ///   be read.
    public func projects() throws -> [ProjectRegistryRecord] {
        try storedRecords().filter { record in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: record.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    /// Every record that decodes, in file order. The registry is a cache
    /// the user layer can regenerate, so a line that does not decode is
    /// logged and skipped instead of refusing the whole file.
    ///
    /// - Returns: The decoded records. A missing file gives none.
    /// - Throws: A file-system error when an existing registry file cannot
    ///   be read.
    private func storedRecords() throws -> [ProjectRegistryRecord] {
        guard FileManager.default.fileExists(atPath: registryFile.path) else {
            return []
        }
        let text = try String(contentsOf: registryFile, encoding: .utf8)
        let decoder = JSONLines.makeDecoder()
        return text.split(separator: "\n").compactMap { line in
            decodedRecord(fromLine: line, decoder: decoder)
        }
    }

    /// The record `line` holds, or `nil` after a `warning` log record when
    /// the line does not decode. The log record holds the path of the
    /// registry file and never the text of the line, because a line holds a
    /// project path.
    ///
    /// - Parameters:
    ///   - line: One line of the registry file, without its newline.
    ///   - decoder: The decoder of the record lines.
    /// - Returns: The decoded record, or `nil` for a line the read skips.
    private func decodedRecord(fromLine line: Substring, decoder: JSONDecoder) -> ProjectRegistryRecord? {
        do {
            return try decoder.decode(ProjectRegistryRecord.self, from: Data(line.utf8))
        } catch {
            RouterTelemetry.makeLogger(.projectRegistry).warning(
                "The project registry skipped a line that does not decode.",
                metadata: [RouterTelemetry.LogMetadataKey.filePath: .string(registryFile.path)])
            return nil
        }
    }

    /// Replaces the registry file with `records`, one line each.
    ///
    /// - Parameter records: The records the file holds afterwards.
    /// - Throws: An encode error, or a file-system error when the write
    ///   fails.
    private func write(_ records: [ProjectRegistryRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONLines.replaceFile(registryFile, withLinesOf: records)
    }
}
