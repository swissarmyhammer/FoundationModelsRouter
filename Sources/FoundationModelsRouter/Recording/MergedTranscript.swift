import Foundation

/// A failure reading the recorded transcripts a merge covers.
enum MergedTranscriptError: Error, Equatable, LocalizedError {
    /// A line of the transcript at `file` that is NOT the file's last line
    /// failed to decode.
    ///
    /// A torn *final* line is the expected crash artifact of
    /// ``JSONLRecorder``'s durability policy and is dropped with a warning
    /// instead; corruption anywhere before it means the log was damaged after
    /// it was written, which no policy expects, so it is reported loudly with
    /// the file it names.
    case transcriptLineCorrupt(file: URL)

    /// A localized message describing what error occurred.
    var errorDescription: String? {
        switch self {
        case .transcriptLineCorrupt(let file):
            return """
                Transcript \(file.path) holds a corrupt line before its last one, so the recorded \
                log cannot be trusted.
                """
        }
    }
}

/// Merges the per-session `transcript.jsonl` files a run left under a router's
/// recording root into the single "what did this whole Router do" event stream.
///
/// Each session (and each fork) records into its own lineage-nested
/// `transcript.jsonl`, so the on-disk tree mirrors the fork lineage but no one
/// file holds the whole run. ``merged(under:)`` reads every nested file and
/// interleaves them back into one totally-ordered stream.
///
/// The order is by `(ts, seq)`: the ULID-nested paths already give near-order,
/// but the true total order is the one the single recorder stamped. `ts` is the
/// primary key and `seq` — globally monotonic across every session and fork the
/// recorder served — is the tiebreaker, so events sharing an instant still fall
/// into their exact recorded order even under concurrent generation.
public enum MergedTranscript {
    /// Merges every nested `transcript.jsonl` under `routerDirectory` into one
    /// stream totally ordered by `(ts, seq)`.
    ///
    /// Line decoding is shared with ``TranscriptTree`` so the two readers
    /// cannot drift: a torn FINAL line in any one file — the crash artifact
    /// ``JSONLRecorder``'s durability policy expects — is dropped with a
    /// warning naming the file and byte offset, rather than failing the merge.
    ///
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — under which the session transcript files are
    ///   nested.
    /// - Returns: Every recorded event across all sessions and forks, ordered by
    ///   `(ts, seq)`.
    /// - Throws: ``MergedTranscriptError/transcriptLineCorrupt(file:)`` when a
    ///   file holds a corrupt line before its last one;
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when a session's sidecar carries a schema version newer than
    ///   ``RecordingSchemaVersion/current`` (see
    ///   ``checkSchemaVersion(besideTranscript:)``); otherwise if a
    ///   transcript file cannot be read.
    public static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        // Discovery is shared with ``TranscriptTree`` through
        // ``TranscriptFileDiscovery``; the files come back in no particular
        // order, and the decoded events — not the files — are sorted below.
        let files = TranscriptFileDiscovery.fileURLs(named: "transcript.jsonl", under: routerDirectory)
        for file in files {
            try checkSchemaVersion(besideTranscript: file)
            events += try TranscriptLineDecoding.decodeEvents(at: file) { file in
                MergedTranscriptError.transcriptLineCorrupt(file: file)
            }
        }
        return events.sorted { ($0.ts, $0.seq) < ($1.ts, $1.seq) }
    }

    /// Refuses a transcript whose session sidecar carries a schema version
    /// newer than this reader knows, before any of its lines are decoded.
    ///
    /// The version is stamped once per session, on the `session.json` beside
    /// the transcript (see ``SessionSidecar/schemaVersion``), so the merge
    /// consults that sidecar for each file it is about to read — the same
    /// gate ``TranscriptTree/load(under:)`` reaches through
    /// ``SessionSidecar/read(in:)``, so the two readers cannot drift.
    ///
    /// The merge's own contract stays otherwise sidecar-free: a transcript
    /// with no `session.json` beside it merges as it always has (there is no
    /// stamped version to gate on), and a sidecar that fails to decode states
    /// no version either — ``TranscriptTree`` is the reader that reports
    /// sidecar absence and corruption loudly.
    ///
    /// - Parameter file: The `transcript.jsonl` about to be decoded.
    /// - Throws: ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when the sidecar beside `file` names a version newer than
    ///   ``RecordingSchemaVersion/current``.
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
