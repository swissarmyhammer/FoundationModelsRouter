import Foundation

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
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — under which the session transcript files are
    ///   nested.
    /// - Returns: Every recorded event across all sessions and forks, ordered by
    ///   `(ts, seq)`.
    /// - Throws: If a transcript file cannot be read or a line cannot be decoded.
    public static func merged(under routerDirectory: URL) throws -> [TranscriptEvent] {
        let decoder = JSONDecoder()
        var events: [TranscriptEvent] = []
        for file in transcriptFiles(under: routerDirectory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                events.append(try decoder.decode(TranscriptEvent.self, from: Data(line.utf8)))
            }
        }
        return events.sorted { ($0.ts, $0.seq) < ($1.ts, $1.seq) }
    }

    /// Finds every `transcript.jsonl` nested at any depth under `routerDirectory`.
    ///
    /// - Parameter routerDirectory: The recording root to search.
    /// - Returns: The URLs of the discovered transcript files, in no particular
    ///   order — ``merged(under:)`` sorts the decoded events, not the files.
    private static func transcriptFiles(under routerDirectory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: routerDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "transcript.jsonl" {
            files.append(url)
        }
        return files
    }
}
