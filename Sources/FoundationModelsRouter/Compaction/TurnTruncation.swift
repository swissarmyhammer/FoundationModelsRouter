import FoundationModels

/// Deterministic compaction stage 2: drops the oldest complete turns. A turn
/// is never split.
package struct TurnTruncation: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    package static let stageName = "TurnTruncation"

    /// How many of the newest turns are the untouchable recency window. Defaults to `4`.
    package var keepRecentTurns: Int

    /// Creates a turn-truncation stage that keeps `keepRecentTurns` newest turns. Defaults to `4`.
    package init(keepRecentTurns: Int = 4) {
        self.keepRecentTurns = keepRecentTurns
    }

    /// Applies truncation to `transcript`. Pure. Returns the header plus the recency window.
    package func apply(_ transcript: Transcript) -> Transcript {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        return Transcript(entries: header + recent.flatMap(\.entries))
    }
}
