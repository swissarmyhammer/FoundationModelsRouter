import Foundation
import FoundationModelsExtras
import Logging

/// The root sessions on disk under the recording roots of the host: the
/// record of past sessions that ``RouterSessionDirectory`` owns (ROUTER-3,
/// D72).
///
/// Each recording root holds `sessions.jsonl` (``SessionIndex``) beside the
/// recording directory of each of its root sessions. A summary of a recorded
/// session comes from its index record, its `session.json`
/// (``SessionSidecar``) and its `facts.json` (``SessionFacts``), and it is
/// never live:
///
/// - The kind is `root`, or `subagent` of the spawning session when the
///   sidecar holds an `agentSpawn`.
/// - The state is `archived` when the facts hold `archivedAt`, else `idle`.
/// - The title is the title of the facts, else the title of the record; an
///   empty title counts as none.
/// - `updatedAt` is the later of the record's `updatedAt` and the
///   modification date of `facts.json`; `createdAt` is the time of the ULID.
/// - A session with no `facts.json` (recorded before the file existed) has
///   empty facts, so it maps to the default agent and the client origin.
///
/// The index lists root sessions only, so a fork or a subagent whose folder
/// sits inside the folder of its parent has no recorded summary. The index is
/// append-only and a resume appends a second line for a session, so the last
/// record of a session id wins.
struct RecordedSessions {
    /// One index record, its session id and the session directory it names.
    private struct LocatedRecord {
        /// The index record.
        let record: SessionIndexRecord

        /// The session id of ``record``.
        let id: ULID

        /// The session directory of ``record`` under its recording root.
        let directory: URL
    }

    /// The recording roots of the host.
    let roots: [URL]

    /// The summaries of the root sessions recorded under ``roots``.
    ///
    /// - Returns: One summary for each recorded root session, in no order.
    /// - Throws: The read error of an index (``SessionIndex/read()``), of a
    ///   `session.json` or of a `facts.json`.
    func summaries() throws -> [SessionSummary] {
        try latestRecords().compactMap(Self.summary(of:))
    }

    /// The last record of each session id in the indexes of ``roots``, in
    /// root order and then file order.
    ///
    /// - Returns: One located record for each session id, in no order.
    /// - Throws: The read error of an index.
    private func latestRecords() throws -> [LocatedRecord] {
        let located = try roots.flatMap { root in
            try SessionIndex(root: root).read().records.compactMap { Self.locate($0, under: root) }
        }
        return Array(Dictionary(located.map { ($0.id, $0) }) { _, later in later }.values)
    }

    /// The located form of one index record, or `nil` with a logged warning
    /// when its session id is not a ULID.
    ///
    /// - Parameters:
    ///   - record: A record of the index of `root`.
    ///   - root: The recording root that holds the index.
    /// - Returns: The located record, or `nil` for a record the call skipped.
    private static func locate(_ record: SessionIndexRecord, under root: URL) -> LocatedRecord? {
        let directory = root.appendingPathComponent(record.sessionId, isDirectory: true)
        guard let id = ULID(ulidString: record.sessionId) else {
            logSkippedRecord("a session index record whose session id is not a ULID was skipped", in: directory)
            return nil
        }
        return LocatedRecord(record: record, id: id, directory: directory)
    }

    /// The summary of the session of one located record, or `nil` with a
    /// logged warning when its session directory is gone.
    ///
    /// - Parameter located: The located record.
    /// - Returns: The summary, or `nil` for a record the call skipped.
    /// - Throws: The read error of the `session.json` or the `facts.json` of
    ///   the session.
    private static func summary(of located: LocatedRecord) throws -> SessionSummary? {
        guard FileManager.default.fileExists(atPath: located.directory.path) else {
            logSkippedRecord("a session index record whose session directory is gone was skipped", in: located.directory)
            return nil
        }
        let sidecar = try SessionSidecar.read(in: located.directory)
        let facts = try SessionFacts.read(from: located.directory) ?? SessionFacts()
        let spawn = sidecar?.agentSpawn
        return SessionSummary(
            id: located.id,
            agentID: facts.agentID ?? RouterSessionDirectory.defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: sidecar?.workingDirectory ?? URL(fileURLWithPath: located.record.cwd, isDirectory: true),
            title: title(of: facts, recordedAs: located.record),
            tags: facts.tags,
            kind: spawn == nil ? .root : .subagent,
            state: facts.archivedAt == nil ? .idle : .archived,
            parentID: spawn?.parentSessionId,
            startedBy: facts.startedBy,
            origin: facts.origin ?? RouterSessionDirectory.defaultOrigin,
            createdAt: located.id.timestamp,
            updatedAt: updatedAt(of: located),
            isLive: false)
    }

    /// The title of a recorded session: the title of its facts, else the
    /// title of its index record. An empty title counts as none.
    ///
    /// - Parameters:
    ///   - facts: The facts of the session.
    ///   - record: The index record of the session.
    /// - Returns: The title, or `nil` when neither holds one.
    private static func title(of facts: SessionFacts, recordedAs record: SessionIndexRecord) -> String? {
        [facts.title, record.title].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The time of the last change of a recorded session: the later of the
    /// `updatedAt` of its record and the modification date of its
    /// `facts.json`, which changes when a fact changes after the record.
    ///
    /// - Parameter located: The located record.
    /// - Returns: The time of the last change.
    private static func updatedAt(of located: LocatedRecord) -> Date {
        let factsFile = located.directory.appendingPathComponent(SessionFacts.fileName, isDirectory: false)
        let values = try? factsFile.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = values?.contentModificationDate else { return located.record.updatedAt }
        return max(located.record.updatedAt, modified)
    }

    /// Logs one warning for an index record that gives no summary: the
    /// constant `message` and the path of the session directory the record
    /// names. The record's other fields stay out of the log.
    ///
    /// - Parameters:
    ///   - message: The constant log message.
    ///   - directory: The session directory the record names.
    private static func logSkippedRecord(_ message: Logger.Message, in directory: URL) {
        RouterTelemetry.makeLogger(.sessionIndex).warning(
            message, metadata: [RouterTelemetry.LogMetadataKey.filePath: "\(directory.path)"])
    }

    /// Appends the `sessions.jsonl` line of a new durable root session to
    /// the index of the folder that holds its recording directory (the
    /// decision of the user on ROUTER-3: the directory writes the index).
    ///
    /// Only a ``RoutedSessionActor`` that is new under a durable root and
    /// records its facts (``SessionSidecarOrigin/recordsFacts``) appends. A
    /// restored session already has its line, and a memory-only session has
    /// nothing on disk to list. A failed append is logged and dropped: it
    /// never fails the registration.
    ///
    /// - Parameter session: The root session.
    static func appendIndexRecord(of session: any RoutedSession) {
        guard let actor = session as? RoutedSessionActor, case .new = actor.sidecarOrigin,
            actor.sidecarOrigin.recordsFacts
        else { return }
        let root = session.recordingDirectory.deletingLastPathComponent()
        let record = SessionIndexRecord(
            sessionId: session.id.description, cwd: session.workingDirectory.path,
            title: session.facts.title ?? "", updatedAt: Date(), additionalDirectories: [])
        do {
            try SessionIndex(root: root).append(record)
        } catch {
            RouterTelemetry.makeLogger(.sessionIndex).error(
                "the session index line of a new root session was dropped",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.sessionId: "\(session.id)"
                ]) { _, new in new })
        }
    }
}
