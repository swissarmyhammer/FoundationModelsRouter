import Foundation
import FoundationModels

/// What one compaction pipeline run did (compaction_plan.md §1.4): how big
/// the transcript was before and after, which stages actually ran, and —
/// once the model-assisted ``Summarization`` stage is wired in — the
/// synthesized summary text.
///
/// `tokensBefore`/`tokensAfter` are ``Compactor``'s character-ratio estimate
/// (compaction_plan.md §1.5) when produced by the model-free pipeline alone;
/// a live session wiring this pipeline in (`RoutedSession.compact(prompt:budget:)`,
/// a later build-order step) supplies its own measured counts instead — the
/// next real turn always re-measures exactly, so an estimate here is safe.
public struct CompactionResult: Sendable, Equatable {
    /// The synthesized fold summary, or `nil` when no ``Summarization``
    /// ran — either no `summarizer` was supplied to
    /// ``Compactor/compact(_:prompt:budget:summarizer:)`` (the model-free
    /// fallback), the deterministic stages alone already landed the
    /// transcript under target, or there was no old span left to summarize
    /// (the oversized-tail case).
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

/// The compaction pipeline (compaction_plan.md §1.3): runs the deterministic
/// stages, in order, until the transcript lands under ``TokenBudget/target``,
/// then — when a `summarizer` is supplied — falls back to the model-assisted
/// ``Summarization`` stage; reports the shortfall when even that isn't
/// enough.
///
/// `summarizer` is `nil` by default: without one, this degrades to the
/// model-free pipeline exactly as before — ``CompactionResult/summary`` stays
/// `nil` and only ``ToolOutputElision``/``TurnTruncation`` ever run. `prompt`
/// is only ever used by ``Summarization``, so it is ignored entirely on that
/// model-free path.
///
/// `compact(_:prompt:budget:summarizer:)` returns both the folded transcript
/// and the report: compaction_plan.md §1.1 describes compaction itself as a
/// pure `Transcript -> Transcript` function (model-assisted summarization
/// aside, which needs to call out to `summarizer`), and both entry points
/// that build on this pipeline need the folded transcript itself —
/// `RoutedSessionActor.compact` swaps it in as the session's new inner
/// transcript, and the bare-session recipe hands it to
/// `RecordingLanguageModel.noteCompaction(_:)` and rebuilds
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

    /// Runs the pipeline over `transcript`, folding it down to at most
    /// `budget.target` of `budget.limit`.
    ///
    /// Stages run in order (``ToolOutputElision`` first, then
    /// ``TurnTruncation``, then — only when `summarizer` is non-`nil` —
    /// ``Summarization``) and the pipeline stops as soon as one lands the
    /// transcript under target. When the transcript is already under target,
    /// no stage runs. When every deterministic stage runs without success and
    /// either no `summarizer` was supplied or ``Summarization`` finds no old
    /// span left to fold (the recency window itself is too large, and no
    /// stage may touch it) — the *original* transcript is returned unchanged
    /// (``CompactionResult/stagesApplied`` is empty) with the shortfall
    /// reported via ``CompactionResult/tokensAfter``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold.
    ///   - prompt: The compaction prompt ``Summarization`` sends to
    ///     `summarizer`, verbatim, when it runs. Defaults to
    ///     ``CompactionPrompt/default``. Unused on the model-free path (no
    ///     `summarizer` supplied, or the deterministic stages alone suffice).
    ///   - budget: The token budget to fold against.
    ///   - summarizer: The model ``Summarization`` calls to condense the
    ///     folded span, or `nil` to degrade to the model-free pipeline
    ///     (``ToolOutputElision``/``TurnTruncation`` only —
    ///     ``CompactionResult/summary`` stays `nil`). Defaults to `nil`.
    /// - Returns: The folded transcript (unchanged from `transcript` when no
    ///   stage helped enough) and a report of what happened.
    /// - Throws: Whatever `summarizer.summarize(_:)` throws, unmodified, when
    ///   ``Summarization`` runs and the summarizer call fails.
    public static func compact(
        _ transcript: Transcript,
        prompt: CompactionPrompt = .default,
        budget: TokenBudget,
        summarizer: (any CompactionSummarizer)? = nil
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
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

        // Model-assisted last resort: only attempted when a summarizer is
        // available, and always over the *original* transcript — see
        // Summarization's own doc comment for why it cannot operate on
        // `current` at this point (TurnTruncation already dropped the old
        // turns' content from it).
        if let summarizer,
            let folded = try await Summarization().apply(
                transcript,
                prompt: prompt,
                tokensBefore: tokensBefore,
                priorStagesApplied: stagesApplied,
                summarizer: summarizer
            )
        {
            let tokensAfter = estimatedTokenCount(of: folded.transcript)
            return (
                folded.transcript,
                CompactionResult(
                    summary: folded.summary,
                    tokensBefore: tokensBefore,
                    tokensAfter: tokensAfter,
                    stagesApplied: stagesApplied + [Summarization.stageName]
                )
            )
        }

        // Oversized tail: every available stage ran and the transcript is
        // still over target — the recency window alone is too big, and
        // nothing may touch it. `current` at this point may be smaller than
        // `transcript` (old turns folded away in the discarded attempt), but
        // the function returns the *original* transcript unchanged, so
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
        return estimatedTokenCount(bytes: totalBytes)
    }

    /// Estimates `text`'s size in tokens using the same
    /// ``charsPerTokenEstimate`` character-ratio ``estimatedTokenCount(of:)``
    /// applies to a whole transcript — shared so a single-string estimate
    /// (e.g. ``ToolOutputCapping``'s tool-output cap, task 1334fk3) is
    /// measured consistently with the transcript-level one.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count.
    static func estimatedTokenCount(of text: String) -> Int {
        estimatedTokenCount(bytes: text.utf8.count)
    }

    /// Converts a raw byte count into an estimated token count via
    /// ``charsPerTokenEstimate``, rounding up — the shared arithmetic both
    /// ``estimatedTokenCount(of:)`` overloads apply to their respective byte
    /// counts (a transcript's total payload size, or a single string's UTF-8
    /// size).
    ///
    /// - Parameter bytes: The byte count to convert.
    /// - Returns: The estimated token count.
    private static func estimatedTokenCount(bytes: Int) -> Int {
        Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))
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
