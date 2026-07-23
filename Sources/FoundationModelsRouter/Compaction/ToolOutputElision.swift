import FoundationModels

/// Deterministic compaction stage 1 (compaction_plan.md §1.3): replaces
/// `toolOutput` payloads older than the recency window with a one-line
/// placeholder naming the tool. Tool traffic is the bulk of an agentic
/// transcript and old outputs are stale anyway, so this is the near-free win
/// ``Compactor`` tries first, before falling back to ``TurnTruncation``.
///
/// `toolCalls`/`toolOutput` pairing is preserved: only the `toolOutput`
/// entry's payload shrinks, in place, under its original id — its matching
/// `toolCalls` entry, and every other entry, is untouched. The recency window
/// (the newest ``keepRecentTurns`` turns) survives verbatim.
public struct ToolOutputElision: CompactionStage {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied``.
    public static let stageName = "ToolOutputElision"

    /// How many of the newest turns are the untouchable recency window.
    /// Defaults to `4` (compaction_plan.md §1.3).
    public var keepRecentTurns: Int

    /// Creates a tool-output-elision stage.
    ///
    /// - Parameter keepRecentTurns: How many of the newest turns to leave
    ///   untouched. Defaults to `4`.
    public init(keepRecentTurns: Int = 4) {
        self.keepRecentTurns = keepRecentTurns
    }

    /// Applies elision to `transcript`, returning the result. Pure: the same
    /// input always yields the same output.
    ///
    /// - Parameter transcript: The transcript to elide old tool output from.
    /// - Returns: A transcript with old `toolOutput` payloads replaced by
    ///   one-line placeholders; the header and recency window are untouched.
    public func apply(_ transcript: Transcript) -> Transcript {
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
