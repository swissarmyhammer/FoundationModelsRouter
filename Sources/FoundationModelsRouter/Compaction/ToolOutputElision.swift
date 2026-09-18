import FoundationModels

/// Deterministic compaction stage 1: replaces `toolOutput` payloads older
/// than the recency window with a one-line placeholder naming the tool. The
/// `toolOutput` entry keeps its id; every other entry is untouched. A tool
/// output that ``protection`` protects is untouched too.
package struct ToolOutputElision: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    package static let stageName = "ToolOutputElision"

    /// How many of the newest turns are the untouchable recency window. Defaults to `4`.
    package var keepRecentTurns: Int

    /// The host rule whose protected tool outputs this stage never elides, or
    /// `nil` to elide every old tool output.
    package var protection: ToolOutputProtection?

    /// Creates a tool-output-elision stage.
    ///
    /// - Parameters:
    ///   - keepRecentTurns: How many of the newest turns to leave untouched. Defaults to `4`.
    ///   - protection: The host rule whose protected tool outputs stay
    ///     unchanged, or `nil` (the default) to elide every old tool output.
    package init(keepRecentTurns: Int = 4, protection: ToolOutputProtection? = nil) {
        self.keepRecentTurns = keepRecentTurns
        self.protection = protection
    }

    /// Applies elision to `transcript`. Pure.
    ///
    /// - Parameter transcript: The transcript to elide old tool output from.
    /// - Returns: A transcript with old unprotected `toolOutput` payloads
    ///   replaced by placeholders.
    package func apply(_ transcript: Transcript) -> Transcript {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (old, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)

        let elidedOld = old.map(elidingUnprotected)

        return Transcript(entries: header + elidedOld.flatMap(\.entries) + recent.flatMap(\.entries))
    }

    /// Returns `turn` with each tool output elided, except the tool outputs
    /// ``protection`` protects.
    ///
    /// - Parameter turn: An old turn.
    /// - Returns: The turn with its unprotected tool outputs elided.
    private func elidingUnprotected(_ turn: TranscriptTurn) -> TranscriptTurn {
        let protected = ProtectedToolOutputs(entries: turn.entries, rule: protection)
        return TranscriptTurn(
            entries: turn.entries.indices.map { position in
                protected.isProtectedOutput(at: position)
                    ? turn.entries[position] : Self.eliding(turn.entries[position])
            })
    }

    /// Replaces `entry` with a one-line placeholder naming the tool when it
    /// is a `.toolOutput` entry; every other entry kind (notably its pairing
    /// `.toolCalls`) passes through unchanged.
    ///
    /// - Parameter entry: The entry to consider for elision.
    /// - Returns: The elided entry, or `entry` unchanged.
    private static func eliding(_ entry: Transcript.Entry) -> Transcript.Entry {
        guard case .toolOutput(var toolOutput) = entry else { return entry }
        toolOutput.segments = [
            .text(
                Transcript.TextSegment(
                    id: "\(toolOutput.id)-elided",
                    content: "[elided: original \"\(toolOutput.toolName)\" output omitted by compaction]"
                )
            )
        ]
        return .toolOutput(toolOutput)
    }
}
