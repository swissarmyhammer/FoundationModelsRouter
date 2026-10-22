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
    ///   when a session's sidecar names a schema version newer than
    ///   ``RecordingSchemaVersion/current``; otherwise
    ///   `JSONLFileError.readFailed(description:)` when a transcript file
    ///   cannot be read, which aborts the whole merge.
    static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        // Discovery is shared with ``TranscriptTree`` through
        // ``TranscriptFileDiscovery``; the files come back in no particular
        // order, and the decoded events — not the files — are sorted below.
        let files = TranscriptFileDiscovery.fileURLs(named: transcriptFileName, under: routerDirectory)
        let events = try files.flatMap { file in
            try checkSchemaVersion(besideTranscript: file)
            return try JSONLFile(url: file).records(as: TranscriptEvent.self)
        }
        return events.sorted { ($0.ts, $0.seq) < ($1.ts, $1.seq) }
    }

    /// Refuses a transcript whose session sidecar carries a schema version
    /// newer than this reader knows, before any of its lines are decoded.
    ///
    /// The version is stamped once per session, on the `session.json` beside
    /// the transcript (see ``SessionSidecar/schemaVersion``), so the merge
    /// consults that sidecar for each file it is about to read — the same gate
    /// ``TranscriptTree/load(under:)`` reaches through
    /// ``SessionSidecar/read(in:)``, so the two readers cannot drift.
    ///
    /// The merge stays otherwise sidecar-free: a transcript with no
    /// `session.json` beside it, or one whose sidecar cannot be decoded, merges
    /// as before. ``TranscriptTree`` is the reader that reports sidecar absence
    /// and corruption loudly.
    private static func checkSchemaVersion(besideTranscript file: URL) throws {
        do {
            _ = try SessionSidecar.read(in: file.deletingLastPathComponent())
        } catch let error as RecordingSchemaVersionError {
            throw error
        } catch {
            // An absent sidecar returns nil (no throw); reaching here means
            // one exists but cannot be decoded, so it states no version to
            // gate on. The merge keeps its historical sidecar-free contract
            // for that file rather than adopting TranscriptTree's loud
            // corruption reporting.
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
    ///   when a session's sidecar names a schema version newer than this build
    ///   supports, or `JSONLFileError.readFailed(description:)` when a
    ///   transcript file cannot be read, which aborts the whole merge.
    public static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        try MergedTranscript.merged(under: routerDirectory)
    }
}
