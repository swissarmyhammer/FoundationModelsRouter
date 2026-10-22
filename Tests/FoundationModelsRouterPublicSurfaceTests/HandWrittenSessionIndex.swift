import Foundation
import FoundationModelsExtras

import FoundationModelsRouter

/// A session folder a consumer makes by hand: a folder named by the session
/// id under a recording root, with an `index.md` that holds the record of the
/// session as YAML frontmatter. The frontmatter holds the keys a record must
/// have and the optional keys a test gives.
///
/// A plain-import test cannot reach the package's own writer of the file, so
/// it writes the text, as a host or a tool outside Router can.
enum HandWrittenSessionIndex {
    /// The name of the file in a session folder.
    static let fileName = "index.md"

    /// The working context, in tokens, the record holds.
    private static let context = 1_000

    /// The recording schema version the record holds: the current one.
    private static let schemaVersion = 3

    /// Writes a session folder with an `index.md` under `root`.
    ///
    /// - Parameters:
    ///   - id: The session id: the name of the folder.
    ///   - root: The recording root. It is made when it is not there.
    ///   - workingDirectory: The path of the working folder, the key `cwd`.
    ///   - updatedAt: The ISO 8601 text, in UTC with milliseconds, of the
    ///     last activity.
    ///   - title: The title, or `nil` for none.
    ///   - optionalLines: More frontmatter lines, as YAML text, for keys such
    ///     as `firstActivityAt` or `agentSpawn`.
    ///   - body: The body below the frontmatter.
    /// - Returns: The session folder.
    /// - Throws: The error of the making of the folder or the write of the
    ///   file.
    @discardableResult
    static func write(
        id: ULID,
        under root: URL,
        workingDirectory: String,
        updatedAt: String,
        title: String?,
        optionalLines: [String] = [],
        body: String = ""
    ) throws -> URL {
        let folder = root.appendingPathComponent(id.description, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = [
            "---",
            "sessionId: \(id)",
            "cwd: \(workingDirectory)",
            "updatedAt: \(updatedAt)",
            "slot: standard",
            "model: org/std-a",
            "context: \(context)",
            "recordingLevel: full",
            "routerId: \(ULID.generate())",
            "schemaVersion: \(schemaVersion)",
        ]
        if let title {
            lines.append("title: \(title)")
        }
        lines.append(contentsOf: optionalLines)
        lines.append("---")
        let text = lines.joined(separator: "\n") + "\n" + body
        try text.write(
            to: folder.appendingPathComponent(fileName, isDirectory: false), atomically: true, encoding: .utf8)
        return folder
    }
}
