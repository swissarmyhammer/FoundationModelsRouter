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
        try readEntries(depth: .direct).map(\.record)
    }

    /// The records of the sessions recorded under ``roots`` at any depth: the
    /// root sessions, and also each session whose folder sits inside the
    /// folder of another session, as a recorded fork or a sub-agent can.
    ///
    /// Each `index.md` under a root, in a folder named by a ULID, is a
    /// record. If two roots hold a folder with one id, the first root wins.
    ///
    /// - Returns: One record for each recorded session, newest first
    ///   (``SessionRecord/sessionId`` descending).
    /// - Throws: The read error of an `index.md` that exists
    ///   (``SessionIndexFile/read(in:)``).
    func nestedRecords() throws -> [SessionRecord] {
        try nestedEntries().map(\.record)
    }

    /// The sessions recorded under ``roots`` at any depth, each with its
    /// record and its folder. The same walk as ``nestedRecords()``.
    ///
    /// - Returns: One entry for each recorded session, newest first.
    /// - Throws: What ``nestedRecords()`` throws.
    func nestedEntries() throws -> [Entry] {
        try readEntries(depth: .nested)
    }

    /// A recorded session: its record and the folder that holds it.
    struct Entry {
        /// The record of the session, from its `index.md`.
        let record: SessionRecord

        /// The recording folder of the session.
        let folder: URL
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

    /// How deep a listing looks for the folder of a session under a root.
    private enum Depth {
        /// Only the entries of the root.
        case direct

        /// A folder at any depth under the root.
        case nested
    }

    /// The sessions that ``roots`` hold at `depth`. This is the one root walk
    /// of ``records()`` and ``nestedEntries()``: if two roots hold a folder
    /// with one id, the first root wins.
    ///
    /// - Parameter depth: How deep the listing of each root looks.
    /// - Returns: One entry for each recorded session, newest first.
    /// - Throws: The error of a listing of a root that exists, or the read
    ///   error of an `index.md` that exists.
    private func readEntries(depth: Depth) throws -> [Entry] {
        let folders = try roots.flatMap { try Self.sessionFolders(under: $0, depth: depth) }
        let firstFolders = Dictionary(folders, uniquingKeysWith: { first, _ in first })
        return try firstFolders.values
            .compactMap { folder in try SessionIndexFile.read(in: folder).map { Entry(record: $0, folder: folder) } }
            .sorted { $0.record.sessionId > $1.record.sessionId }
    }

    /// The session folders of `root` at `depth`: each folder named by a ULID,
    /// in root order. A `direct` listing takes each entry of the root. A
    /// `nested` listing takes each folder at any depth that holds an
    /// `index.md`.
    ///
    /// - Parameters:
    ///   - root: A recording root.
    ///   - depth: How deep the listing looks.
    /// - Returns: The id and the folder of each session, or none when `root`
    ///   does not exist.
    /// - Throws: The error of the listing of a root that exists.
    private static func sessionFolders(under root: URL, depth: Depth) throws -> [(ULID, URL)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let candidates: [URL]
        switch depth {
        case .direct:
            candidates = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        case .nested:
            candidates = TranscriptFileDiscovery
                .fileURLs(named: SessionIndexFile.fileName, under: root)
                .map { $0.deletingLastPathComponent() }
        }
        return candidates.compactMap { folder in
            ULID(ulidString: folder.lastPathComponent).map { ($0, folder) }
        }
    }
}
