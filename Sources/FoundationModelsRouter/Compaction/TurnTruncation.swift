import FoundationModels

/// Deterministic compaction stage 2: drops the oldest complete turns. A turn
/// is never split. The protected tool outputs of a dropped turn stay: each
/// one, with the `.toolCalls` entry that holds its call reduced to the
/// protected calls, moves right after the header in its original order.
package struct TurnTruncation: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    package static let stageName = "TurnTruncation"

    /// How many of the newest turns are the untouchable recency window. Defaults to `4`.
    package var keepRecentTurns: Int

    /// The host rule whose protected tool outputs this stage never drops, or
    /// `nil` to drop each old turn whole.
    package var protection: ToolOutputProtection?

    /// Creates a turn-truncation stage.
    ///
    /// - Parameters:
    ///   - keepRecentTurns: How many of the newest turns to keep. Defaults to `4`.
    ///   - protection: The host rule whose protected tool outputs stay, or
    ///     `nil` (the default) to drop each old turn whole.
    package init(keepRecentTurns: Int = 4, protection: ToolOutputProtection? = nil) {
        self.keepRecentTurns = keepRecentTurns
        self.protection = protection
    }

    /// Applies truncation to `transcript`. Pure. Returns the header, the
    /// protected pairs of the dropped turns, then the recency window.
    package func apply(_ transcript: Transcript) -> Transcript {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (old, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        let kept = old.flatMap { ProtectedToolOutputs(entries: $0.entries, rule: protection).keptEntries }
        return Transcript(entries: header + kept + recent.flatMap(\.entries))
    }
}
