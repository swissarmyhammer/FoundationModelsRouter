import Foundation
import FoundationModelsExtras

/// The root sessions on disk under the recording roots of the host: the
/// record of past sessions that ``RouterSessionDirectory`` owns (ROUTER-3,
/// D72).
///
/// Each recording root holds the recording folder of each of its root
/// sessions, named by the session id. A listing reads the folders of each
/// root: an entry that is a folder named by a ULID is a root session, and
/// any other entry is not. A summary of a recorded session comes from the
/// `session.json` (``SessionSidecar``) and the `facts.json`
/// (``SessionFacts``) in its folder, and it is never live:
///
/// - The kind is `root`, or `subagent` of the spawning session when the
///   sidecar holds an `agentSpawn`.
/// - The state is `archived` when the facts hold `archivedAt`, else `idle`.
/// - The title is the title of the facts; an empty title counts as none.
/// - The working folder is the one of the sidecar, else the session folder,
///   as ``SessionSidecar`` falls back to its own folder.
/// - `updatedAt` is the latest modification date of `session.json`,
///   `facts.json` and `transcript.jsonl`; `createdAt` is the time of the
///   ULID, which is also `updatedAt` when no file has a date.
/// - A session with no `facts.json` has empty facts, so it maps to the
///   default agent and the client origin.
///
/// A fork or a subagent whose folder sits inside the folder of its parent is
/// not an entry of the root, so it has no recorded summary. If two roots hold
/// a folder with one id, the first root wins, as
/// ``RouterSessionDirectory`` reads the ledger of a recorded session from the
/// first root that holds its folder.
struct RecordedSessions {
    /// The recording roots of the host.
    let roots: [URL]

    /// The files of a session folder whose modification dates give the
    /// `updatedAt` of its summary.
    private static let activityFileNames = [sessionSidecarFileName, SessionFacts.fileName, transcriptFileName]

    /// The summaries of the root sessions recorded under ``roots``.
    ///
    /// - Returns: One summary for each recorded root session, in no order.
    /// - Throws: The error of a listing of a root that exists, or the read
    ///   error of a `session.json` or of a `facts.json`.
    func summaries() throws -> [SessionSummary] {
        let folders = try roots.flatMap(Self.sessionFolders(under:))
        let firstFolders = Dictionary(folders, uniquingKeysWith: { first, _ in first })
        return try firstFolders.map { id, folder in try Self.summary(of: id, in: folder) }
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

    /// The summary of the recorded session `id` from its folder.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - folder: The session folder.
    /// - Returns: The summary.
    /// - Throws: The read error of the `session.json` or the `facts.json` of
    ///   the session.
    private static func summary(of id: ULID, in folder: URL) throws -> SessionSummary {
        let sidecar = try SessionSidecar.read(in: folder)
        let facts = try SessionFacts.read(from: folder) ?? SessionFacts()
        let spawn = sidecar?.agentSpawn
        return SessionSummary(
            id: id,
            agentID: facts.agentID ?? RouterSessionDirectory.defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: sidecar?.workingDirectory ?? folder,
            title: facts.title.flatMap { $0.isEmpty ? nil : $0 },
            tags: facts.tags,
            kind: spawn == nil ? .root : .subagent,
            state: facts.archivedAt == nil ? .idle : .archived,
            parentID: spawn?.parentSessionId,
            startedBy: facts.startedBy,
            origin: facts.origin ?? RouterSessionDirectory.defaultOrigin,
            createdAt: id.timestamp,
            updatedAt: lastActivity(in: folder) ?? id.timestamp,
            isLive: false)
    }

    /// The latest modification date of the activity files of a session
    /// folder (``activityFileNames``).
    ///
    /// - Parameter folder: The session folder.
    /// - Returns: The latest date, or `nil` when no activity file has one.
    private static func lastActivity(in folder: URL) -> Date? {
        activityFileNames.compactMap { fileName in
            let file = folder.appendingPathComponent(fileName, isDirectory: false)
            return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }
}
