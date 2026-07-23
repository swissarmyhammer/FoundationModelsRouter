import Foundation
import FoundationModels

/// What one compaction pipeline run did (compaction_plan.md §1.4): how big
/// the transcript was before and after, which stages actually ran, and —
/// once the model-assisted `Summarization` stage (a later build-order step)
/// is wired in — the synthesized summary text.
///
/// `tokensBefore`/`tokensAfter` are ``Compactor``'s character-ratio estimate
/// (compaction_plan.md §1.5) when produced by the model-free pipeline alone;
/// a live session wiring this pipeline in (`RoutedSession.compact(prompt:budget:)`,
/// a later build-order step) supplies its own measured counts instead — the
/// next real turn always re-measures exactly, so an estimate here is safe.
public struct CompactionResult: Sendable, Equatable {
    /// The synthesized fold summary, or `nil` for a model-free run (no
    /// `Summarization` stage applied — this pipeline never adds one).
    public let summary: String?

    /// The transcript's estimated size, in tokens, before this pipeline ran.
    public let tokensBefore: Int

    /// The transcript's estimated size, in tokens, after this pipeline ran —
    /// equal to ``tokensBefore`` when no stage was applied (already under
    /// target, or an oversized recency window made every stage insufficient).
    public let tokensAfter: Int

    /// The stages that actually ran, in order — empty when the transcript
    /// was already under target, or when every stage ran but still left the
    /// transcript over target (the oversized-tail case, where the original
    /// transcript is returned unchanged rather than partially folded).
    public let stagesApplied: [String]

    /// Creates a compaction result.
    ///
    /// - Parameters:
    ///   - summary: The synthesized fold summary, or `nil`.
    ///   - tokensBefore: The estimated pre-fold size, in tokens.
    ///   - tokensAfter: The estimated post-fold size, in tokens.
    ///   - stagesApplied: The stages that ran, in order.
    public init(summary: String?, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String]) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.stagesApplied = stagesApplied
    }
}

/// The model-free compaction pipeline (compaction_plan.md §1.3, build-order
/// step 4): runs deterministic stages, in order, until the transcript lands
/// under ``TokenBudget/target``, or reports the shortfall when even every
/// stage together isn't enough.
///
/// This pipeline takes **no prompt parameter** — it never summarizes.
/// ``CompactionResult/summary`` is always `nil` here; the model-assisted
/// `Summarization` stage (a later build-order step) adds a `prompt:
/// CompactionPrompt` parameter and wires itself in as the pipeline's final
/// stage.
///
/// `compact(_:budget:)` returns both the folded transcript and the report:
/// compaction_plan.md §1.1 describes compaction itself as a pure `Transcript
/// -> Transcript` function, and both entry points that build on this
/// pipeline need the folded transcript itself — `RoutedSessionActor.compact`
/// swaps it in as the session's new inner transcript, and the bare-session
/// recipe hands it to `RecordingLanguageModel.noteCompaction(_:)` and rebuilds
/// `LanguageModelSession(model:tools:transcript:)` over it.
public enum Compactor {
    /// The deterministic stages this pipeline runs, in order, each at its
    /// default `keepRecentTurns` (compaction_plan.md §1.3): `ToolOutputElision`
    /// first (the near-free win), then `TurnTruncation` (the fallback).
    static let stages: [any CompactionStage] = [ToolOutputElision(), TurnTruncation()]

    /// The characters-per-token ratio ``estimatedTokenCount(of:)`` uses to
    /// turn a transcript's on-disk-payload byte size into a token estimate
    /// (compaction_plan.md §1.5's "prospective size check"), in the absence
    /// of any live model measurement at this layer: `Compactor` is a pure
    /// function over a bare `Transcript`, with no session and no backend to
    /// ask for real usage. `4.0` is the commonly cited average for English
    /// text under BPE-style tokenizers — safe as a *relative* estimate
    /// (before vs. after the same transcript, measured the same way) even
    /// though it is never exact, because the next real turn re-measures the
    /// live window exactly and replaces it (§1.5).
    static let charsPerTokenEstimate: Double = 4.0

    /// Runs the deterministic pipeline over `transcript`, folding it down to
    /// at most `budget.target` of `budget.limit`.
    ///
    /// Stages run in order (``ToolOutputElision`` first, then
    /// ``TurnTruncation``) and the pipeline stops as soon as one lands the
    /// transcript under target. When the transcript is already under target,
    /// no stage runs. When even every stage together leaves the transcript
    /// over target — the recency window itself is too large, and neither
    /// stage may touch it — the *original* transcript is returned unchanged
    /// (``CompactionResult/stagesApplied`` is empty) with the shortfall
    /// reported via ``CompactionResult/tokensAfter``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold.
    ///   - budget: The token budget to fold against.
    /// - Returns: The folded transcript (unchanged from `transcript` when no
    ///   stage helped enough) and a report of what happened.
    public static func compact(
        _ transcript: Transcript,
        budget: TokenBudget
    ) -> (transcript: Transcript, result: CompactionResult) {
        let tokensBefore = estimatedTokenCount(of: transcript)
        let targetTokens = Int((Double(budget.limit) * budget.target).rounded())

        guard tokensBefore > targetTokens else {
            return (
                transcript,
                CompactionResult(summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [])
            )
        }

        var current = transcript
        var stagesApplied: [String] = []

        for stage in stages {
            current = stage.apply(current)
            stagesApplied.append(type(of: stage).stageName)

            let estimated = estimatedTokenCount(of: current)
            if estimated <= targetTokens {
                return (
                    current,
                    CompactionResult(
                        summary: nil, tokensBefore: tokensBefore, tokensAfter: estimated, stagesApplied: stagesApplied)
                )
            }
        }

        // Oversized tail: every deterministic stage ran and the transcript is
        // still over target — the recency window alone is too big, and
        // neither stage may touch it. `current` at this point may be smaller
        // than `transcript` (old turns folded away in the discarded attempt),
        // but the function returns the *original* transcript unchanged, so
        // `tokensAfter` must report `tokensBefore` — the size of what is
        // actually being returned — not `current`'s size.
        return (
            transcript,
            CompactionResult(summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [])
        )
    }

    /// Estimates `transcript`'s size in tokens: the total on-disk-payload
    /// byte size of every entry (via ``TranscriptEntryMapper``, which maps
    /// every entry kind — segments, tool calls, tool definitions — without
    /// throwing), divided by ``charsPerTokenEstimate``.
    ///
    /// Reusing the payload mapper keeps this estimate honest about *every*
    /// content-bearing field a stage might shrink (segment text, tool-call
    /// arguments, tool names), not just `.text` segments.
    ///
    /// - Parameter transcript: The transcript to estimate.
    /// - Returns: The estimated token count.
    static func estimatedTokenCount(of transcript: Transcript) -> Int {
        let totalBytes = transcript.reduce(into: 0) { total, entry in
            total += payloadByteCount(of: entry)
        }
        return Int((Double(totalBytes) / charsPerTokenEstimate).rounded(.up))
    }

    /// The JSON-encoded byte size of `entry`'s ``TranscriptEntryPayload``
    /// mirror — a proxy for its textual content size across every entry kind.
    ///
    /// - Parameter entry: The entry to measure.
    /// - Returns: The entry's payload size in bytes, or `0` when it cannot be
    ///   encoded (unreachable in practice: `TranscriptEntryMapper.event(from:)`
    ///   never produces a payload its own `Codable` conformance can't encode).
    private static func payloadByteCount(of entry: Transcript.Entry) -> Int {
        let (_, payload, _) = TranscriptEntryMapper.event(from: entry)
        guard let data = try? JSONEncoder().encode(payload) else { return 0 }
        return data.count
    }
}
