import Foundation
import FoundationModelsExtras
import Logging

/// The facts of one recorded session that change after it starts: its
/// agent, its tags, its title, who started it, how it started and when it
/// was archived (ROUTER-1).
///
/// They live in `facts.json` in the session's own recording directory,
/// beside the write-once ``SessionSidecar`` (`session.json`). The sidecar
/// holds the facts fixed at creation and is never rewritten; this file is
/// overwritten whole, atomically, on each change.
///
/// The schema is additive, like the sidecar's: a key this reader does not
/// know is ignored, an absent key decodes as its documented absent value,
/// and a file stamped with a ``schemaVersion`` newer than
/// ``currentSchemaVersion`` is refused rather than misread.
public struct SessionFacts: Codable, Sendable, Equatable {
    /// The file's name in a session's recording directory.
    public static let fileName = "facts.json"

    /// Version 1: the first shape of `facts.json`.
    private static let v1 = 1

    /// The version a write stamps, and the version a file with no
    /// `schemaVersion` key decodes as.
    public static let currentSchemaVersion = v1

    /// The resolved id of the session's agent (D71): a catalog id (`default`
    /// for the root agent) or `folder:` plus the absolute path of a folder
    /// agent. Router stores it as given and never resolves it. `nil` when no
    /// agent was recorded.
    public var agentID: String?

    /// The display name of the agent, from the `name` key of its `AGENT.md`,
    /// or `nil`.
    public var agentName: String?

    /// The tags of the session. Absent in a file, it decodes as no tags.
    public var tags: Set<String>

    /// The title a user or a session gave the session, or `nil`.
    public var title: String?

    /// The session that started this root session (a tool, a message or a
    /// trigger), or `nil`. It is not a parent: the session is not a subagent.
    public var startedBy: ULID?

    /// How the root session started, or `nil` when it was not recorded.
    public var origin: FoundationModelsExtras.SessionDirectoryOrigin?

    /// The instant the session was archived (D68), or `nil` for a session
    /// that is not archived.
    public var archivedAt: Date?

    /// The schema version of the file. A file with no `schemaVersion` key
    /// decodes as ``currentSchemaVersion``.
    public let schemaVersion: Int

    /// Makes the facts of a session. Every field defaults to its absent
    /// value.
    ///
    /// - Parameters:
    ///   - agentID: The resolved agent id. The default is `nil`.
    ///   - agentName: The display name of the agent. The default is `nil`.
    ///   - tags: The tags. The default is none.
    ///   - title: The title. The default is `nil`.
    ///   - startedBy: The session that started this one. The default is `nil`.
    ///   - origin: How the session started. The default is `nil`.
    ///   - archivedAt: The archive instant. The default is `nil`.
    public init(
        agentID: String? = nil,
        agentName: String? = nil,
        tags: Set<String> = [],
        title: String? = nil,
        startedBy: ULID? = nil,
        origin: FoundationModelsExtras.SessionDirectoryOrigin? = nil,
        archivedAt: Date? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.tags = tags
        self.title = title
        self.startedBy = startedBy
        self.origin = origin
        self.archivedAt = archivedAt
        self.schemaVersion = Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case agentID, agentName, tags, title, startedBy, origin, archivedAt, schemaVersion
    }

    /// Decodes the facts by the additive rule: an absent `tags` key is no
    /// tags, an absent `schemaVersion` key is ``currentSchemaVersion``, and
    /// each other absent key is `nil`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when a present key holds the wrong type.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        startedBy = try container.decodeIfPresent(ULID.self, forKey: .startedBy)
        origin = try container.decodeIfPresent(
            FoundationModelsExtras.SessionDirectoryOrigin.self, forKey: .origin)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    }

    /// Reads the facts in a session's recording directory.
    ///
    /// - Parameter directory: The session's recording directory.
    /// - Returns: The facts, or `nil` when the directory holds no
    ///   `facts.json`.
    /// - Throws: ``RecordingSchemaVersionError`` when the file's
    ///   ``schemaVersion`` is newer than ``currentSchemaVersion``; otherwise a
    ///   read or decode error.
    public static func read(from directory: URL) throws -> SessionFacts? {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let facts = try JSONLines.makeDecoder().decode(
            SessionFacts.self, from: try Data(contentsOf: fileURL))
        guard facts.schemaVersion <= currentSchemaVersion else {
            throw RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: directory, version: facts.schemaVersion, supported: currentSchemaVersion)
        }
        return facts
    }

    /// Writes the facts into a session's recording directory as `facts.json`,
    /// replacing any earlier file. The write is atomic: the bytes go to a
    /// temporary file that is then renamed over the old one, so a reader sees
    /// the old facts or the new facts, never a part. Unlike
    /// ``SessionSidecar``, the file is meant to be overwritten. The bytes are
    /// one record in the encoding of ``JSONLines``: sorted keys and RFC 3339
    /// dates, so a rewrite of equal facts gives equal bytes.
    ///
    /// - Parameter directory: The session's recording directory. It must
    ///   exist.
    /// - Throws: An encode error, or a file-system error when the write fails.
    public func write(to directory: URL) throws {
        let fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        try JSONLines.makeEncoder().encode(self).write(to: fileURL, options: .atomic)
    }

    /// The first facts of a fork taken from a session with these facts: the
    /// agent id, the agent name and the tags of the source, origin
    /// ``FoundationModelsExtras/SessionDirectoryOrigin/fork``, and no title,
    /// no `startedBy` and no archive date.
    var forFork: SessionFacts {
        SessionFacts(agentID: agentID, agentName: agentName, tags: tags, origin: .fork)
    }

    /// The facts a restored session holds: the ones in its `facts.json`, or
    /// empty facts for a session recorded before the file existed. The
    /// missing file is not an error: it logs one warning with the path of
    /// the directory, and no file is written.
    ///
    /// - Parameter directory: The restored session's recording directory.
    /// - Returns: The recorded facts, or empty facts.
    /// - Throws: What ``read(from:)`` throws for a file that is there but
    ///   cannot be read: a damaged file, or a newer ``schemaVersion``.
    static func restored(from directory: URL) throws -> SessionFacts {
        guard let recorded = try read(from: directory) else {
            RouterTelemetry.makeLogger(.recording).warning(
                "the restored session has no facts.json; it restores with empty facts",
                metadata: [RouterTelemetry.LogMetadataKey.filePath: "\(directory.path)"])
            return SessionFacts()
        }
        return recorded
    }
}
