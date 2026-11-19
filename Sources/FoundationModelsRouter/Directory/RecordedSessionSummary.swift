import Foundation
import FoundationModelsExtras

extension SessionSummary {
    /// Makes the summary of a recorded session from its record alone
    /// (``RecordedSessions``, D207). This is the recorded summary that
    /// ``RouterSessionDirectory`` gives, before the directory adds the pin and
    /// the last use of its usage store, and before it gives a default name to
    /// a recorded root session with no title.
    ///
    /// The initializer is pure: it reads no file and no folder.
    ///
    /// - The kind is `fork` and the parent is the source when the record
    ///   holds a ``SessionRecord/forkParentId``, else the kind is `subagent`
    ///   and the parent is the spawning session when the record holds an
    ///   ``SessionRecord/agentSpawn``, else the kind is `root` with no parent.
    /// - The state is `archived` when the facts hold `archivedAt`, else
    ///   `idle`. The summary is never live.
    /// - The title is the title of the facts; an empty title counts as none.
    ///   With no title, the slug is the 7-character short id.
    /// - The last summary, the recap, the time of the recap and
    ///   ``SessionSummary/archivedAt`` are those of the facts (D206), and
    ///   ``SessionSummary/importedFrom`` is the provenance of the facts
    ///   (D209 (h)).
    /// - A record with no agent or no origin maps to the default agent and
    ///   the client origin.
    ///
    /// - Parameter record: The record of the session.
    public init(record: SessionRecord) {
        let facts = record.facts
        let lineage = SessionRecord.directoryLineage(forkSource: record.forkParentId, agentSpawn: record.agentSpawn)
        self.init(
            id: record.sessionId,
            agentID: facts.agentID ?? RouterSessionDirectory.defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: record.workingDirectory,
            title: SessionDefaultTitle.given(facts.title),
            tags: facts.tags,
            kind: lineage.kind,
            state: facts.archivedAt == nil ? .idle : .archived,
            parentID: lineage.parentID,
            startedBy: facts.startedBy,
            origin: facts.origin ?? RouterSessionDirectory.defaultOrigin,
            createdAt: record.sessionId.timestamp,
            updatedAt: record.updatedAt,
            lastSummary: facts.lastSummary,
            isLive: false,
            archivedAt: facts.archivedAt,
            recap: facts.recap,
            recapAt: facts.recapAt,
            importedFrom: facts.importedFrom)
    }
}
