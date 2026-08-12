import Foundation

/// The registry of on-disk recording schema versions — every version a
/// recording can carry, each constant documented with what that version added.
///
/// One version is stamped per session, on its ``SessionSidecar`` (never per
/// event line: a session's sidecar and its `transcript.jsonl` are written by
/// one router build, so one stamp covers both, and per-line stamping would
/// bloat every event for no reader benefit). The stamp is what lets a reader
/// distinguish "this field is `nil` because the recording predates it" from
/// "this field is `nil` because it was legitimately absent" — the ambiguity
/// that forced ``TranscriptEntryPayload/contentRemoved``'s decode-as-`false`
/// workaround.
///
/// Readers gate on it: ``SessionSidecar/read(in:)`` refuses a version newer
/// than ``current`` with
/// ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``,
/// while an equal or older version keeps decoding by the additive rule — a
/// field the version predates decodes as its documented absent-value, exactly
/// as today.
public enum RecordingSchemaVersion {
    /// Version 1: the initial recording shape.
    ///
    /// Flat ``TranscriptEvent`` lines carrying `text` only, the deprecated
    /// ``TranscriptEvent/Kind/toolCall`` kind, and no
    /// ``TranscriptEvent/entry`` payload at all.
    public static let v1 = 1

    /// Version 2: additive structural payloads over ``v1``.
    ///
    /// Added ``TranscriptEvent/entry`` (``TranscriptEntryPayload``), the
    /// entry kinds mirroring the SDK's own transcript cases
    /// (``TranscriptEvent/Kind/instructions``,
    /// ``TranscriptEvent/Kind/toolCalls``,
    /// ``TranscriptEvent/Kind/reasoning``), and
    /// ``TranscriptEntryPayload/contentRemoved``.
    ///
    /// The optional ``SessionSidecar/configuration`` envelope (task
    /// ^ne5g9jn) landed *within* v2 by the additive rule: it is a new
    /// optional key old readers never look for, an absent key decodes as
    /// `nil`, and a `nil` envelope restores with the pre-envelope defaults —
    /// so no version bump was needed.
    ///
    /// The unknown-case carriers (task ^9n7fna4) also landed within v2:
    /// ``TranscriptEvent/Kind/unknown`` and
    /// ``SegmentPayload/unknown(id:description:)``, which record a
    /// `Transcript.Entry` or `Transcript.Segment` case a future SDK adds. A
    /// deliberate decision, with a known limit. This build can only write a
    /// carrier when it runs on a future OS whose SDK has more cases than the
    /// SDK it compiled against; on the current SDK, recordings are unchanged,
    /// so a bump of ``current`` would make every old reader refuse every new
    /// recording to guard against a value that cannot occur yet. The limit:
    /// an old v2 reader that meets a carrier-bearing recording gets a decode
    /// error rather than the typed
    /// ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    /// refusal. When a future SDK case becomes known and the mapper maps it
    /// as a real kind, that shape change must be born versioned.
    public static let v2 = 2

    /// The version writers stamp on every new sidecar
    /// (see ``SessionSidecar/schemaVersion``).
    public static let current = v2

    /// The version a sidecar with no `schemaVersion` key decodes as — the
    /// newest shape ever written before the stamp existed.
    ///
    /// Frozen at ``v2`` forever: a future bump of ``current`` must not move
    /// this, since every unstamped recording on disk was written at or before
    /// the v2 shape.
    public static let implicit = v2
}

/// A recording stamped with a schema version newer than this reader knows —
/// written by a newer router, and refused rather than silently misread.
///
/// Thrown by ``SessionSidecar/read(in:)``, so every reader that decodes a
/// sidecar — ``TranscriptTree/load(under:)``, ``MergedTranscript/merged(under:)``,
/// and the restore paths built on them — surfaces the same typed refusal.
public enum RecordingSchemaVersionError: Error, Equatable, LocalizedError {
    /// `directory`'s sidecar carries `version`, newer than `supported` — the
    /// newest version this reader knows (``RecordingSchemaVersion/current``).
    case recordingFromNewerRouter(directory: URL, version: Int, supported: Int)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .recordingFromNewerRouter(let directory, let version, let supported):
            return """
                Recording at \(directory.path) carries schema version \(version), newer than the \
                newest version this reader knows (\(supported)). It was written by a newer router \
                and cannot be read without misreading it.
                """
        }
    }
}
