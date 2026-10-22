import Foundation
import FoundationModelsExtras

/// The root sessions on disk under the recording roots of the host: the
/// record of past sessions that ``RouterSessionDirectory`` owns (ROUTER-3,
/// D72).
///
/// Each recording root holds the recording folder of each of its root
/// sessions, named by the session id. A listing reads the folders of each
/// root: an entry that is a folder named by a ULID and holds an `index.md`
/// (``SessionIndexFile``) is a root session, and any other entry is not.
/// The ``SessionRecord`` in the frontmatter of that `index.md` is all a
/// listing reads, and a summary made from it is never live:
///
/// - The kind is `root`, or `subagent` of the spawning session when the
///   record holds an ``SessionRecord/agentSpawn``.
/// - The state is `archived` when the facts hold `archivedAt`, else `idle`.
/// - The title is the title of the facts; an empty title counts as none.
/// - The working folder is ``SessionRecord/workingDirectory``.
/// - `updatedAt` is ``SessionRecord/updatedAt``; `createdAt` is the time of
///   the ULID.
/// - A record with no agent or no origin maps to the default agent and the
///   client origin.
///
/// A fork or a subagent whose folder sits inside the folder of its parent is
/// not an entry of the root, so it has no recorded summary. If two roots hold
/// a folder with one id, the first root wins, as
/// ``RouterSessionDirectory`` reads the ledger of a recorded session from the
/// first root that holds its folder.
struct RecordedSessions {
    /// The recording roots of the host.
    let roots: [URL]

    /// The records of the root sessions recorded under ``roots``.
    ///
    /// - Returns: One record for each recorded root session, newest first
    ///   (``SessionRecord/sessionId`` descending).
    /// - Throws: The error of a listing of a root that exists, or the read
    ///   error of an `index.md` that exists (``SessionIndexFile/read(in:)``).
    func records() throws -> [SessionRecord] {
        let folders = try roots.flatMap(Self.sessionFolders(under:))
        let firstFolders = Dictionary(folders, uniquingKeysWith: { first, _ in first })
        return try firstFolders.values
            .compactMap(SessionIndexFile.read(in:))
            .sorted { $0.sessionId > $1.sessionId }
    }

    /// The summaries of the root sessions recorded under ``roots``.
    ///
    /// - Returns: One summary for each recorded root session, newest first.
    /// - Throws: What ``records()`` throws.
    func summaries() throws -> [SessionSummary] {
        try records().map(Self.summary(of:))
    }

    /// The summary of a recorded session, made from its record alone.
    ///
    /// - Parameter record: The record of the session.
    /// - Returns: The summary. It is never live.
    static func summary(of record: SessionRecord) -> SessionSummary {
        let facts = record.facts
        let spawn = record.agentSpawn
        return SessionSummary(
            id: record.sessionId,
            agentID: facts.agentID ?? RouterSessionDirectory.defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: record.workingDirectory,
            title: facts.title.flatMap { $0.isEmpty ? nil : $0 },
            tags: facts.tags,
            kind: spawn == nil ? .root : .subagent,
            state: facts.archivedAt == nil ? .idle : .archived,
            parentID: spawn?.parentSessionId,
            startedBy: facts.startedBy,
            origin: facts.origin ?? RouterSessionDirectory.defaultOrigin,
            createdAt: record.sessionId.timestamp,
            updatedAt: record.updatedAt,
            isLive: false)
    }

    /// The root session folders of `root`: each entry that is a folder named
    /// by a ULID, in root order.
    ///
    /// - Parameter root: A recording root.
    /// - Returns: The id and the folder of each root session, or none when
    ///   `root` does not exist.
    /// - Throws: The error of the listing of a root that exists.
    private static func sessionFolders(under root: URL) throws -> [(ULID, URL)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let id = ULID(ulidString: entry.lastPathComponent)
            else { return nil }
            return (id, entry)
        }
    }
}
