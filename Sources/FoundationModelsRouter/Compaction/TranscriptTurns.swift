import FoundationModels

/// One logical turn within a ``Transcript``: the entries from a `.prompt`
/// entry up to (but not including) the next `.prompt` entry, in original
/// order — the prompt itself plus whatever `.toolCalls`/`.toolOutput` pairs,
/// `.reasoning`, and `.response` entries that turn produced.
///
/// Used by the deterministic compaction stages (compaction_plan.md §1.3,
/// ``ToolOutputElision``, ``TurnTruncation``) to partition a transcript into
/// "old" turns eligible for folding and a "recent" tail that must survive
/// verbatim, without ever splitting a turn or orphaning a tool-call pair.
struct TranscriptTurn {
    /// This turn's entries, in original order, starting with its `.prompt`.
    var entries: [Transcript.Entry]
}

/// Splits a transcript's entries into turns and partitions them by recency
/// (compaction_plan.md §1.3's `keepRecentTurns` window) — the shared
/// mechanism every deterministic compaction stage builds on.
enum TranscriptTurns {
    /// Splits `entries` into a leading header — everything before the first
    /// `.prompt` entry, normally just `.instructions` — and the ordered turns
    /// that follow. A transcript with no `.prompt` entry at all (e.g.
    /// instructions only) yields an empty `turns` array; the header is never
    /// touched by any stage (compaction_plan.md §1.3's "instructions never
    /// modified or dropped" invariant).
    ///
    /// - Parameter entries: The transcript's entries, in original order.
    /// - Returns: The header entries and the ordered turns.
    static func split(_ entries: [Transcript.Entry]) -> (header: [Transcript.Entry], turns: [TranscriptTurn]) {
        var header: [Transcript.Entry] = []
        var turns: [TranscriptTurn] = []
        var current: [Transcript.Entry] = []

        for entry in entries {
            if case .prompt = entry {
                if !current.isEmpty {
                    turns.append(TranscriptTurn(entries: current))
                }
                current = [entry]
            } else if current.isEmpty {
                header.append(entry)
            } else {
                current.append(entry)
            }
        }
        if !current.isEmpty {
            turns.append(TranscriptTurn(entries: current))
        }
        return (header, turns)
    }

    /// Partitions `turns` into the "old" turns eligible for folding and the
    /// "recent" tail that must survive verbatim: the newest `keepRecentTurns`
    /// turns, or every turn when there are fewer than `keepRecentTurns` —
    /// never splitting a turn between the two groups.
    ///
    /// `keepRecentTurns <= 0` protects nothing: every turn is eligible for
    /// folding (`old: turns, recent: []`) — the "keep the newest zero turns"
    /// reading, and the maximally aggressive setting a caller can ask for.
    ///
    /// - Parameters:
    ///   - turns: The transcript's turns, in original order.
    ///   - keepRecentTurns: How many of the newest turns are the untouchable
    ///     recency window.
    /// - Returns: The old (foldable) turns and the recent (untouchable) tail.
    static func partition(
        _ turns: [TranscriptTurn],
        keepRecentTurns: Int
    ) -> (old: [TranscriptTurn], recent: [TranscriptTurn]) {
        guard keepRecentTurns > 0 else {
            return (turns, [])
        }
        guard turns.count > keepRecentTurns else {
            return ([], turns)
        }
        let splitIndex = turns.count - keepRecentTurns
        return (Array(turns[..<splitIndex]), Array(turns[splitIndex...]))
    }
}
