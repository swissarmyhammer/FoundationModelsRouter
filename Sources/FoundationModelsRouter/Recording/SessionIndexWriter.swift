import Foundation

/// The durable transcripts root of a model handle, paired with the run-level
/// facts each session under it records in its `index.md`.
package struct DurableRecording: Sendable {
    /// The router's durable transcripts root.
    package let root: URL

    /// The run-level facts every session under ``root`` records.
    package let indexWriter: SessionIndexWriter

    /// Pairs a durable transcripts root with its index writer.
    package init(root: URL, indexWriter: SessionIndexWriter) {
        self.root = root
        self.indexWriter = indexWriter
    }
}

/// The run-level facts of the `index.md` of each session that one
/// ``RoutedModel`` vends: how much the run records, and its resolved profile.
/// A session with a writer that ``writes`` keeps its ``SessionRecord`` in
/// the `index.md` of its session folder; a session with no writer, or with
/// an ``RecordingLevel/off`` writer, holds it in memory alone.
package struct SessionIndexWriter: Sendable {
    /// How much of each session's activity is recorded.
    let recordingLevel: RecordingLevel

    /// The run's resolved profile, recorded onto root sessions only.
    let profile: SessionRecord.ResolvedProfile?

    /// Creates an index writer for one resolved model handle.
    ///
    /// - Parameters:
    ///   - recordingLevel: How much of each session's activity is recorded.
    ///   - profile: The run's resolved profile, or `nil`.
    package init(recordingLevel: RecordingLevel, profile: SessionRecord.ResolvedProfile?) {
        self.recordingLevel = recordingLevel
        self.profile = profile
    }

    /// Whether the sessions of this writer keep an `index.md`. Nothing
    /// durable is recorded at ``RecordingLevel/off``: not an `index.md`, and
    /// not a transcript either, since the router's `GatingRecorder` drops
    /// every event at this level.
    var writes: Bool {
        recordingLevel != .off
    }
}

/// Where the first ``SessionRecord`` of a ``RoutedSessionActor`` comes from.
/// Each builder of a session states which case applies.
enum SessionRecordSource: Sendable {
    /// The session is new: vended or forked. It makes its first record from
    /// these first facts and its own construction values, and
    /// `makeRoutedSessionActor` writes that record as its first `index.md`.
    case new(SessionFacts)

    /// The session is a reconstruction of one already on disk, with the
    /// record read from its `index.md`. Construction writes nothing.
    case restored(SessionRecord)
}
