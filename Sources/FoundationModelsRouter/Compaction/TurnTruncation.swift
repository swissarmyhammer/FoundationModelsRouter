import FoundationModels

/// Deterministic compaction stage 2 (compaction_plan.md §1.3): drops the
/// oldest complete turns, never splitting a turn or orphaning a tool pair.
/// Alone, this is the model-free fallback when ``ToolOutputElision`` isn't
/// enough to land the transcript under target.
public struct TurnTruncation: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    public static let stageName = "TurnTruncation"

    /// How many of the newest turns are the untouchable recency window.
    /// Defaults to `4` (compaction_plan.md §1.3).
    public var keepRecentTurns: Int

    /// Creates a turn-truncation stage.
    ///
    /// - Parameter keepRecentTurns: How many of the newest turns to keep.
    ///   Defaults to `4`.
    public init(keepRecentTurns: Int = 4) {
        self.keepRecentTurns = keepRecentTurns
    }

    /// Applies truncation to `transcript`, returning the result. Pure: the
    /// same input always yields the same output.
    ///
    /// - Parameter transcript: The transcript to truncate.
    /// - Returns: A transcript with the oldest turns dropped entirely; the
    ///   header and recency window are untouched.
    public func apply(_ transcript: Transcript) -> Transcript {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        return Transcript(entries: header + recent.flatMap(\.entries))
    }
}
