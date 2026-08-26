import FoundationModels

/// One logical turn within a ``Transcript``: the entries from a `.prompt`
/// entry up to, but not including, the next `.prompt` entry, in original
/// order.
package struct TranscriptTurn {
    /// This turn's entries, in original order, starting with its `.prompt`.
    package var entries: [Transcript.Entry]
}

/// Splits a transcript's entries into turns and partitions them by recency,
/// the shared mechanism every deterministic compaction stage builds on.
package enum TranscriptTurns {
    /// Splits `entries` into a leading header (everything before the first
    /// `.prompt` entry) and the ordered turns that follow. No `.prompt` entry
    /// yields an empty `turns` array.
    ///
    /// - Parameter entries: The transcript's entries, in original order.
    /// - Returns: The header entries and the ordered turns.
    package static func split(_ entries: [Transcript.Entry]) -> (
        header: [Transcript.Entry], turns: [TranscriptTurn]
    ) {
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
    package static func partition(
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
