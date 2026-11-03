import Foundation
import FoundationModelsExtras

/// Merges the per-session `transcript.jsonl` files a run left under a router's
/// recording root into the single "what did this whole Router do" event stream.
///
/// Each session (and each fork) records into its own lineage-nested
/// `transcript.jsonl`, so the on-disk tree mirrors the fork lineage but no one
/// file holds the whole run.
///
/// The order is by `(ts, seq)`: the ULID-nested paths already give near-order,
/// but the true total order is the one the single recorder stamped. `ts` is the
/// primary key and `seq` — globally monotonic across every session and fork the
/// recorder served — is the tiebreaker, so events sharing an instant still fall
/// into their exact recorded order even under concurrent generation.
///
/// The type is internal. ``TranscriptEvent/merged(under:)`` is the public entry
/// point a package outside this one reads a merged transcript through.
enum MergedTranscript {
    /// Merges every nested `transcript.jsonl` under `routerDirectory` into one
    /// stream.
    ///
    /// Each file reads through the Extras `JSONLFile`, as ``TranscriptTree``
    /// reads it, so the two readers cannot drift: a torn final line is dropped
    /// with a warning, and a whole line that does not decode is skipped with a
    /// warning, rather than failing the merge.
    ///
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — under which the session transcript files
    ///   are nested.
    /// - Throws:
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when a session's `index.md` names a schema version newer than
    ///   ``RecordingSchemaVersion/current``; otherwise
    ///   `JSONLFileError.readFailed(description:)` when a transcript file
    ///   cannot be read, which aborts the whole merge.
    static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        // Discovery is shared with ``TranscriptTree`` through
        // ``TranscriptFileDiscovery``; the files come back in no particular
        // order, and the decoded events — not the files — are sorted below.
        let files = TranscriptFileDiscovery.fileURLs(named: transcriptFileName, under: routerDirectory)
        let events = try files.flatMap(readChecked(_:))
        return events.sorted(by: isRecordedBefore)
    }

    /// Reads the one `transcript.jsonl` of one session folder.
    ///
    /// The read does not enter a child folder. It reads the file as
    /// ``merged(under:)`` reads each file: the schema version check comes
    /// first, a torn final line is dropped with a warning, and a whole line
    /// that does not decode is skipped with a warning. A folder with no
    /// `transcript.jsonl` gives no events.
    ///
    /// - Parameter sessionDirectory: The folder of one session.
    /// - Throws:
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when the `index.md` of the folder names a schema version newer than
    ///   ``RecordingSchemaVersion/current``; otherwise
    ///   `JSONLFileError.readFailed(description:)` when the transcript file
    ///   cannot be read.
    /// - Returns: The events of the folder, ordered by `(ts, seq)`.
    static func read(sessionDirectory: URL) throws -> [TranscriptEvent] {
        let file = sessionDirectory.appendingPathComponent(transcriptFileName, isDirectory: false)
        return try readChecked(file).sorted(by: isRecordedBefore)
    }

    /// Reads one transcript file, after the check of the schema version of
    /// the session record beside it.
    ///
    /// - Parameter file: The `transcript.jsonl` to read.
    /// - Returns: The events of the file, in the order of its lines.
    /// - Throws: What ``checkSchemaVersion(besideTranscript:)`` or the read
    ///   of the file throws.
    private static func readChecked(_ file: URL) throws -> [TranscriptEvent] {
        try checkSchemaVersion(besideTranscript: file)
        return try JSONLFile(url: file).records(as: TranscriptEvent.self)
    }

    /// The recorded order of two events: `ts` first, and `seq` for events
    /// that share an instant.
    private static func isRecordedBefore(_ lhs: TranscriptEvent, _ rhs: TranscriptEvent) -> Bool {
        (lhs.ts, lhs.seq) < (rhs.ts, rhs.seq)
    }

    /// Refuses a transcript whose session record carries a schema version
    /// newer than this reader knows, before any of its lines are decoded.
    ///
    /// The version is stamped once per session, in the record of the
    /// `index.md` beside the transcript (see ``SessionRecord/schemaVersion``),
    /// so the merge consults that record for each file it is about to read —
    /// the same gate ``TranscriptTree/load(under:)`` reaches through
    /// ``SessionIndexFile/read(in:)``, so the two readers cannot drift.
    ///
    /// The merge needs nothing else from the record: a transcript with no
    /// `index.md` beside it, or one whose `index.md` cannot be decoded,
    /// merges anyway. ``TranscriptTree`` is the reader that reports a missing
    /// or damaged `index.md` loudly.
    ///
    /// - Parameter file: The `transcript.jsonl` about to be read.
    /// - Throws:
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when the record beside it names a newer schema version.
    private static func checkSchemaVersion(besideTranscript file: URL) throws {
        do {
            _ = try SessionIndexFile.read(in: file.deletingLastPathComponent())
        } catch let error as RecordingSchemaVersionError {
            throw error
        } catch {
            // An absent `index.md` returns nil (no throw); reaching here
            // means one exists but cannot be decoded, so it states no version
            // to gate on. The merge reads the transcript anyway rather than
            // adopting TranscriptTree's loud corruption reporting.
        }
    }
}

extension TranscriptEvent {
    /// Reads a merged transcript from disk. This is the supported way to do it.
    ///
    /// Merges every nested `transcript.jsonl` under `routerDirectory` into one
    /// event stream, totally ordered by `(ts, seq)`. Each session, and each
    /// fork, records into its own lineage-nested `transcript.jsonl`, so no one
    /// file holds a whole run; this reads the whole run back.
    ///
    /// The entry point sits on ``TranscriptEvent`` — the element type of the
    /// result — because the merge itself, the internal `MergedTranscript`, is
    /// not part of this package's public surface.
    ///
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — under which the session transcript files
    ///   are nested.
    /// - Returns: Every recorded event under `routerDirectory`, ordered by
    ///   `(ts, seq)`. A line that does not decode is skipped with a warning.
    /// - Throws: The internal `RecordingSchemaVersionError.recordingFromNewerRouter`
    ///   when a session's `index.md` names a schema version newer than this build
    ///   supports, or `JSONLFileError.readFailed(description:)` when a
    ///   transcript file cannot be read, which aborts the whole merge.
    public static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        try MergedTranscript.merged(under: routerDirectory)
    }
}

extension TranscriptEvent {
    /// Reads the recorded events of one session folder from disk.
    ///
    /// Reads only the `transcript.jsonl` of `sessionDirectory`. It does not
    /// enter a child folder, so the events of a sub-agent or a fork that
    /// records in a child folder are not in the result. Use
    /// ``merged(under:)`` to read a whole tree. The read applies the same
    /// schema version check and the same rule for a torn line as
    /// ``merged(under:)``.
    ///
    /// - Parameter sessionDirectory: The folder of one session, which holds
    ///   its `transcript.jsonl`.
    /// - Returns: The events of that folder, ordered by `(ts, seq)`. A line
    ///   that does not decode is skipped with a warning. A folder with no
    ///   transcript file gives no events.
    /// - Throws: The internal `RecordingSchemaVersionError.recordingFromNewerRouter`
    ///   when the `index.md` of the folder names a schema version newer than
    ///   this build supports, or `JSONLFileError.readFailed(description:)`
    ///   when the transcript file cannot be read.
    public static func read(sessionDirectory: URL) throws -> [TranscriptEvent] {
        try MergedTranscript.read(sessionDirectory: sessionDirectory)
    }
}
