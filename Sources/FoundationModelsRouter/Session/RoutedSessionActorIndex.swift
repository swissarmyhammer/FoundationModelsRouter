import Foundation

/// The record of a session (``SessionRecord``): its facts (ROUTER-1), its
/// listing data and its restore data. The session holds the record in
/// ``RoutedSessionActor/recordState`` and, when it records durably
/// (``RoutedSessionActor/persistsIndex``), keeps the `index.md` of its
/// session folder equal to it. Each save is best effort: a failed save is
/// logged, and the session goes on with the new record in memory.
extension RoutedSessionActor {
    /// See ``RoutedSession/facts``.
    nonisolated var facts: SessionFacts {
        recordState.withLock { $0.facts }
    }

    /// The record of this session, as its `index.md` holds it.
    nonisolated var record: SessionRecord {
        recordState.withLock { $0 }
    }

    /// Whether this session keeps its record in the `index.md` of its
    /// session folder: it has an index writer that writes.
    nonisolated var persistsIndex: Bool {
        indexWriter?.writes ?? false
    }

    /// Changes the record of this session: applies `change` to the record,
    /// saves the result to `index.md` when the session records durably, and
    /// holds it. The lock is held across the save, so two changes never
    /// interleave and the file and ``record`` never disagree in order. A
    /// save that fails is logged and dropped; the held record changes
    /// anyway, so the session goes on. Every change of a live record goes
    /// through here: the facts, the title, the tags, the archive date, the
    /// additional folders, the activity and the compaction count.
    ///
    /// - Parameter change: The change to apply to the record.
    /// - Returns: The new record.
    @discardableResult
    nonisolated func updateRecord(_ change: (inout SessionRecord) -> Void) -> SessionRecord {
        recordState.withLock { current in
            change(&current)
            if persistsIndex {
                SessionIndexFile.saveLoggingFailure(current, in: recordingDirectory)
            }
            return current
        }
    }

    /// Changes the facts of this session through ``updateRecord(_:)``.
    ///
    /// - Parameter change: The change to apply to the facts.
    /// - Returns: The new facts.
    @discardableResult
    nonisolated func updateFacts(_ change: (inout SessionFacts) -> Void) -> SessionFacts {
        updateRecord { change(&$0.facts) }.facts
    }

    /// Writes the last summary of `reply` (``SessionStateTracking/lastSummary(of:)``)
    /// to the facts of this session (D206), when the facts hold another one.
    /// Thus the record changes only at the end of an answer that changed the
    /// last summary, and a recorded session gives it after a restart. The
    /// session calls it before it sends ``SessionEvent/answered(_:)``, so the
    /// write is in order with the answer and comes before its caller gets
    /// the reply. Only the answer path of the session writes the last
    /// summary, so no other write comes between the read and the write.
    ///
    /// - Parameter reply: The final reply of an answer.
    nonisolated func recordLastSummary(of reply: String) {
        let summary = SessionStateTracking.lastSummary(of: reply)
        guard facts.lastSummary != summary else { return }
        updateFacts { $0.lastSummary = summary }
    }

    /// Writes the first `index.md` of a new session, which also brings its
    /// session folder into existence. `makeRoutedSessionActor` calls it
    /// once, after the construction and before the session records
    /// anything, so any transcript a reader finds has its `index.md` beside
    /// it. A session that does not record durably writes nothing. A failure
    /// is logged and dropped.
    nonisolated func writeFirstIndex() {
        guard persistsIndex else { return }
        recordState.withLock { current in
            do {
                try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
                try SessionIndexFile.save(current, in: recordingDirectory)
            } catch {
                SessionIndexFile.logDroppedSave(error: error, directory: recordingDirectory)
            }
        }
    }

    /// Marks the start of a submission in the record: ``SessionRecord/updatedAt``
    /// moves to now, and ``SessionRecord/firstActivityAt`` is set at the
    /// first submission of the session.
    nonisolated func recordSubmissionStart() {
        updateRecord { $0.recordActivity(at: Date()) }
    }

    /// Counts one more compaction checkpoint of this session's own
    /// transcript in the record (``SessionRecord/compactionCount``).
    nonisolated func recordCompactionCheckpoint() {
        updateRecord { $0.compactionCount += 1 }
    }
}
