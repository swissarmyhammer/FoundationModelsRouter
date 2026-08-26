import FoundationModels

/// Deterministic compaction stage 1: replaces `toolOutput` payloads older
/// than the recency window with a one-line placeholder naming the tool. The
/// `toolOutput` entry keeps its id; every other entry is untouched.
package struct ToolOutputElision: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    package static let stageName = "ToolOutputElision"

    /// How many of the newest turns are the untouchable recency window. Defaults to `4`.
    package var keepRecentTurns: Int

    /// Creates a tool-output-elision stage.
    ///
    /// - Parameter keepRecentTurns: How many of the newest turns to leave untouched. Defaults to `4`.
    package init(keepRecentTurns: Int = 4) {
        self.keepRecentTurns = keepRecentTurns
    }

    /// Applies elision to `transcript`. Pure.
    ///
    /// - Parameter transcript: The transcript to elide old tool output from.
    /// - Returns: A transcript with old `toolOutput` payloads replaced by placeholders.
    package func apply(_ transcript: Transcript) -> Transcript {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (old, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)

        let elidedOld = old.map { turn in TranscriptTurn(entries: turn.entries.map(Self.eliding)) }

        return Transcript(entries: header + elidedOld.flatMap(\.entries) + recent.flatMap(\.entries))
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
