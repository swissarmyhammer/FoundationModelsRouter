import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The cut of a recorded fork in the recorded history of its parent, as the
/// `index.md` of the fork holds it.
///
/// The recorder of an earlier build wrote both values. A recording that a
/// build made before ``SessionRecord/forkedAtHistoryOrdinal`` existed holds
/// only ``entryCount`` (``legacy``).
struct RecordedForkCut: Equatable {
    /// The cut in append-only history coordinates: the count of entry-kind
    /// events in the effective history of the parent at the cut. `nil` for a
    /// legacy recording.
    let historyOrdinal: Int?

    /// The count of entries that the backend of the parent held at the cut.
    /// After a compaction this is the count of the live window, not the
    /// count of the history.
    let entryCount: Int

    /// The same cut as a recording made before
    /// ``SessionRecord/forkedAtHistoryOrdinal`` existed holds it: the entry
    /// count only.
    var legacy: RecordedForkCut {
        RecordedForkCut(historyOrdinal: nil, entryCount: entryCount)
    }

    /// The cut in the history of a fork whose own history held this cut
    /// when the fork was a root, and whose inherited prefix ends at
    /// `inherited`. Use it only for histories with no compaction, where the
    /// two values of a cut add.
    ///
    /// - Parameter inherited: The cut of the fork in the history of its
    ///   parent.
    /// - Returns: The cut in the effective history of the fork.
    func following(_ inherited: RecordedForkCut) -> RecordedForkCut {
        RecordedForkCut(
            historyOrdinal: (historyOrdinal ?? entryCount) + (inherited.historyOrdinal ?? inherited.entryCount),
            entryCount: entryCount + inherited.entryCount)
    }
}

/// Writes recorded fork trees on disk in the layout and the format that the
/// recorder of an earlier build wrote, so the restore of such a recording
/// stays under test now that no live API forks a session.
///
/// The layout is `<recordingRoot>/<rootId>/<childId>/`: a fork has its
/// folder in the folder of its parent. Each folder holds an `index.md`, and a
/// `transcript.jsonl` when the session recorded an event.
///
/// The parent is a real recorded session. The own events of a fork are the
/// events that a real "donor" session recorded: a root session of the same
/// router whose answers are the answers of the fork. The fixture moves the
/// folder of the donor into the folder of the parent, gives each recorded
/// event the parent id of the fork, and writes the `index.md` of the fork
/// from the record of the parent, as the session factory wrote it for a fork:
/// the fork parent and the cut, the facts of the parent with origin `fork`,
/// no profile and no agent spawn.
enum RecordedForkFixtures {
    /// The cut at the end of the recorded history of a session now: the
    /// count of its effective entry-kind events, and the count of the
    /// entries of its restored transcript.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - recordingRoot: The recording root that holds the tree of the
    ///     session.
    /// - Returns: The cut.
    /// - Throws: What the load or the read of the tree throws.
    static func cut(atEndOf sessionId: ULID, under recordingRoot: URL) throws -> RecordedForkCut {
        let tree = try TranscriptTree.load(under: recordingRoot)
        return RecordedForkCut(
            historyOrdinal: try tree.effectiveEntryEvents(forSession: sessionId).count,
            entryCount: try tree.effectiveTranscript(forSession: sessionId).count)
    }

    /// Makes the closed root session in `donorDirectory` a recorded fork of
    /// the session in `parentDirectory`. The folder of the donor moves into
    /// the folder of the parent. Its `transcript.jsonl` keeps each event as
    /// the recorder wrote it, with the parent id of the fork. Its `index.md`
    /// becomes the record of a fork (``forkRecord(of:id:directory:cut:workingDirectory:)``).
    ///
    /// - Parameters:
    ///   - donorDirectory: The folder of a closed root session. Its id
    ///     becomes the id of the fork.
    ///   - parentDirectory: The folder of the parent session.
    ///   - cut: The cut of the fork in the recorded history of the parent.
    ///   - workingDirectory: The working folder of the fork, or `nil` (the
    ///     default) for the folder of the fork, as a fork with no working
    ///     folder of its own recorded.
    /// - Returns: The folder of the fork.
    /// - Throws: What the reads, the writes or the move throw, or a failed
    ///   `#require` when a folder holds no `index.md`.
    @discardableResult
    static func nest(
        donor donorDirectory: URL, under parentDirectory: URL, cut: RecordedForkCut, workingDirectory: URL? = nil
    ) throws -> URL {
        let parent = try #require(try SessionIndexFile.read(in: parentDirectory))
        let donor = try #require(try SessionIndexFile.read(in: donorDirectory))
        let forkDirectory = parentDirectory.appendingPathComponent(donor.sessionId.description, isDirectory: true)
        try FileManager.default.createDirectory(at: forkDirectory, withIntermediateDirectories: true)

        var record = forkRecord(
            of: parent, id: donor.sessionId, directory: forkDirectory, cut: cut, workingDirectory: workingDirectory)
        record.updatedAt = donor.updatedAt
        record.firstActivityAt = donor.firstActivityAt
        record.compactionCount = donor.compactionCount
        try SessionIndexFile.save(record, in: forkDirectory)

        let transcript = donorDirectory.appendingPathComponent(transcriptFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: transcript.path) {
            let forkTranscript = forkDirectory.appendingPathComponent(transcriptFileName, isDirectory: false)
            for event in try JSONLFile(url: transcript).records(as: TranscriptEvent.self) {
                try JSONLAppend.toDisk(event.withParentId(parent.sessionId), forkTranscript)
            }
        }
        // Any other file of the donor moves as it is.
        let kept: Set<String> = [SessionIndexFile.fileName, transcriptFileName]
        for item in try FileManager.default.contentsOfDirectory(at: donorDirectory, includingPropertiesForKeys: nil)
        where !kept.contains(item.lastPathComponent) {
            try FileManager.default.moveItem(
                at: item, to: forkDirectory.appendingPathComponent(item.lastPathComponent))
        }
        try FileManager.default.removeItem(at: donorDirectory)
        return forkDirectory
    }

    /// Writes a recorded fork of the session in `parentDirectory` that has
    /// no events of its own: a fork that never answered. Its folder holds
    /// only its `index.md`, as the session factory wrote it.
    ///
    /// - Parameters:
    ///   - id: The id of the fork. The default is a new id.
    ///   - parentDirectory: The folder of the parent session.
    ///   - cut: The cut of the fork in the recorded history of the parent.
    ///   - workingDirectory: The working folder of the fork, or `nil` (the
    ///     default) for the folder of the fork.
    /// - Returns: The folder of the fork.
    /// - Throws: What the read or the write throws, or a failed `#require`
    ///   when the parent folder holds no `index.md`.
    @discardableResult
    static func writeFork(
        id: ULID = .generate(), under parentDirectory: URL, cut: RecordedForkCut, workingDirectory: URL? = nil
    ) throws -> URL {
        let parent = try #require(try SessionIndexFile.read(in: parentDirectory))
        let forkDirectory = parentDirectory.appendingPathComponent(id.description, isDirectory: true)
        let record = forkRecord(
            of: parent, id: id, directory: forkDirectory, cut: cut, workingDirectory: workingDirectory)
        try SessionRecordFixtures.write(record, to: forkDirectory)
        return forkDirectory
    }

    /// The record that the session factory of an earlier build wrote as the
    /// first `index.md` of a fork of `parent`: the record of the parent
    /// with the id and the working folder of the fork, the fork parent, the
    /// cut, the agent and the tags of the parent with origin `fork`, no
    /// title, no `startedBy`, no profile, no agent spawn and no first
    /// activity.
    ///
    /// - Parameters:
    ///   - parent: The record of the parent.
    ///   - id: The id of the fork.
    ///   - directory: The folder of the fork.
    ///   - cut: The cut of the fork.
    ///   - workingDirectory: The working folder of the fork, or `nil` for
    ///     `directory`.
    /// - Returns: The record of the fork.
    static func forkRecord(
        of parent: SessionRecord, id: ULID, directory: URL, cut: RecordedForkCut, workingDirectory: URL?
    ) -> SessionRecord {
        var record = parent
        record.sessionId = id
        record.workingDirectory = workingDirectory ?? directory
        record.updatedAt = MillisecondDate.rounded(Date())
        record.firstActivityAt = nil
        record.additionalDirectories = []
        record.forkParentId = parent.sessionId
        record.forkedAtEntryCount = cut.entryCount
        record.forkedAtHistoryOrdinal = cut.historyOrdinal
        record.facts = SessionFacts(
            agentID: parent.facts.agentID, agentName: parent.facts.agentName, tags: parent.facts.tags,
            origin: .fork)
        record.profile = nil
        record.agentSpawn = nil
        record.compactionCount = 0
        return record
    }
}

extension TranscriptEvent {
    /// This event with `parentId` as the parent id: the event that the
    /// recorder writes for the same moment of a session with that parent.
    ///
    /// - Parameter parentId: The parent id.
    /// - Returns: The event.
    fileprivate func withParentId(_ parentId: ULID) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model,
            seq: seq,
            ts: ts,
            kind: kind,
            grammar: grammar,
            text: text,
            tokensIn: tokensIn,
            tokensCached: tokensCached,
            tokensOut: tokensOut,
            ms: ms,
            timeToFirstTokenMs: timeToFirstTokenMs,
            decodeMs: decodeMs,
            callMs: callMs,
            firstTokenSeen: firstTokenSeen,
            outputBuffered: outputBuffered,
            entry: entry,
            agentSpawn: agentSpawn)
    }
}
