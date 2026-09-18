import Foundation
import FoundationModels

/// What one compaction pipeline run did: the transcript size before and
/// after, the stages that ran, and the synthesized summary text.
public struct CompactionResult: Sendable, Equatable {
    /// This fold's own identity, a generated ``ULID`` string.
    public let id: String

    /// The synthesized fold summary, or `nil` when no ``Summarization`` ran.
    public let summary: String?

    /// The summary entry's `Transcript.Entry.id`, or `nil`. Present exactly
    /// when ``summary`` is.
    public let summaryEntryId: String?

    /// The ``ModelRef`` string of the model that wrote ``summary``, or `nil`.
    public let summarizerModel: String?

    /// The transcript's estimated size, in tokens, before this pipeline ran.
    public let tokensBefore: Int

    /// The transcript's estimated size, in tokens, after this pipeline ran.
    public let tokensAfter: Int

    /// The stages that were applied, in order.
    public let stagesApplied: [String]

    /// Whether ``Summarization``'s last-resort cut removed text from
    /// ``summary``. `false` on a result rebuilt from a checkpoint.
    public let summaryCut: Bool

    /// The estimated size, in tokens, of the protected tool outputs the
    /// folded transcript keeps word for word (see ``ToolOutputProtection``).
    /// `0` when the session has no rule, or when the rule protects nothing.
    ///
    /// Protected outputs count against the budget like other entries. When
    /// they keep the fold over ``TokenBudget/targetTokens``, the fold still
    /// completes with the other entries, and ``tokensAfter`` is over the
    /// target. This value tells the host why.
    public let protectedTokens: Int

    /// Creates a compaction result.
    ///
    /// - Parameters:
    ///   - id: This fold's identity. Defaults to a freshly generated ``ULID`` string.
    ///   - summary: The synthesized fold summary, or `nil`.
    ///   - summaryEntryId: The summary entry's `Transcript.Entry.id`, or `nil`. Defaults to `nil`.
    ///   - summarizerModel: The ``ModelRef`` string of the summary's writer, or `nil`. Defaults to `nil`.
    ///   - summaryCut: Whether the last-resort cut removed text from `summary`. Defaults to `false`.
    ///   - tokensBefore: The estimated pre-fold size, in tokens.
    ///   - tokensAfter: The estimated post-fold size, in tokens.
    ///   - stagesApplied: The stages that ran, in order.
    ///   - protectedTokens: The estimated size of the protected tool outputs the
    ///     folded transcript keeps. Defaults to `0`.
    public init(
        id: String = ULID.generate().description,
        summary: String?,
        summaryEntryId: String? = nil,
        summarizerModel: String? = nil,
        summaryCut: Bool = false,
        tokensBefore: Int,
        tokensAfter: Int,
        stagesApplied: [String],
        protectedTokens: Int = 0
    ) {
        self.id = id
        self.summary = summary
        self.summaryEntryId = summaryEntryId
        self.summarizerModel = summarizerModel
        self.summaryCut = summaryCut
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.stagesApplied = stagesApplied
        self.protectedTokens = protectedTokens
    }

    /// Returns a copy of this result that names the model that wrote its
    /// summary, or `self` when there is no summary or no name.
    ///
    /// - Parameter modelName: The ``ModelRef`` string of the summary's writer, or `nil`.
    /// - Returns: The named copy, or `self`.
    func withSummarizerModel(_ modelName: String?) -> CompactionResult {
        guard summary != nil, let modelName else { return self }
        return CompactionResult(
            id: id,
            summary: summary,
            summaryEntryId: summaryEntryId,
            summarizerModel: modelName,
            summaryCut: summaryCut,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            stagesApplied: stagesApplied,
            protectedTokens: protectedTokens
        )
    }
}

/// The logger a fold reports to when its protected tool outputs keep it over
/// its target (see ``Compactor/foldKeptOverTarget(_:stagesApplied:tokensBefore:targetTokens:protection:)``).
private let compactorLogger = makeModuleLogger(category: "Compaction")

/// The compaction pipeline. It runs the deterministic stages in order until
/// the transcript lands under ``TokenBudget/target``, then falls back to the
/// model-assisted ``Summarization`` stage when a `summarizer` is supplied.
/// It reports the shortfall when no stage is enough.
package enum Compactor {
    /// The deterministic stages this pipeline runs, in order.
    ///
    /// - Parameter protection: The host rule whose protected tool outputs
    ///   every stage keeps, or `nil` to protect nothing.
    /// - Returns: The stages, each carrying `protection`.
    static func stages(protecting protection: ToolOutputProtection?) -> [any CompactionStage] {
        [ToolOutputElision(protection: protection), TurnTruncation(protection: protection)]
    }

    /// The characters-per-token ratio ``estimatedTokenCount(of:)`` applies to
    /// a transcript's content bytes.
    package static let charsPerTokenEstimate: Double = 4.0

    /// Runs the pipeline over `transcript` and folds it down to at most
    /// `budget.target` of `budget.limit`. The pipeline stops at the first
    /// stage that lands under target. When no stage is enough, the original
    /// transcript is returned unchanged with an empty
    /// ``CompactionResult/stagesApplied``.
    ///
    /// The one exception is a fold that its protected tool outputs keep over
    /// target: the protected outputs alone are over the target, or the fold
    /// would land under it without them. That fold still completes with the
    /// other entries, because no stage may remove a protected output, and its
    /// ``CompactionResult/protectedTokens`` states why it is over target. The
    /// pipeline runs each stage once, and it never loops.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold.
    ///   - prompt: The compaction prompt ``Summarization`` sends to `summarizer`.
    ///   - budget: The token budget to fold against.
    ///   - summarizer: The model ``Summarization`` calls, or `nil` for the model-free pipeline.
    ///   - summarization: The model-assisted stage and its tuning.
    ///   - pendingRuns: The run-plane summaries of the runs still running, in tracking order.
    ///   - protection: The host rule whose protected tool outputs every stage
    ///     keeps word for word, or `nil` (the default) to protect nothing.
    /// - Returns: The folded transcript and a report of what happened.
    /// - Throws: What `summarizer.summarize(_:maxTokens:)` throws, or
    ///   ``SummarizationError/emptySummary`` when the summary holds no text.
    package static func compact(
        _ transcript: Transcript,
        prompt: CompactionPrompt = .default,
        budget: TokenBudget,
        summarizer: (any CompactionSummarizer)? = nil,
        summarization: Summarization = Summarization(),
        pendingRuns: [CompactionSegment.PendingRunSummary] = [],
        protection: ToolOutputProtection? = nil
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        let tokensBefore = estimatedTokenCount(of: transcript)
        let targetTokens = budget.targetTokens

        // Every exit that returns `transcript` untouched — already under
        // target, and the shortfall at the end — reports the same thing: no
        // stage applied, no summary, and `tokensAfter` naming the size of what
        // is actually being returned. One value, so the two cannot drift.
        let shortfallResult = CompactionResult(
            summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [],
            protectedTokens: protectedTokenCount(of: transcript, protection: protection))

        guard tokensBefore > targetTokens else {
            return (transcript, shortfallResult)
        }

        var current = transcript
        var stagesApplied: [String] = []

        for stage in stages(protecting: protection) {
            current = stage.apply(current)
            stagesApplied.append(type(of: stage).stageName)

            let estimated = estimatedTokenCount(of: current)
            if estimated <= targetTokens {
                return (
                    current,
                    CompactionResult(
                        summary: nil, tokensBefore: tokensBefore, tokensAfter: estimated, stagesApplied: stagesApplied,
                        protectedTokens: protectedTokenCount(of: current, protection: protection))
                )
            }
        }

        // Model-assisted last resort: only attempted when a summarizer is
        // available, and always over the *original* transcript — see
        // Summarization's own doc comment for why it cannot operate on
        // `current` at this point (TurnTruncation already dropped the old
        // turns' content from it).
        if let summarizer,
            let folded = try await summarization.apply(
                transcript,
                prompt: prompt,
                tokensBefore: tokensBefore,
                priorStagesApplied: stagesApplied,
                summarizer: summarizer,
                pendingRuns: pendingRuns,
                protection: protection
            )
        {
            // A fold is applied only when it actually shrank the transcript.
            // Summarizing replaces a span of real conversation with a lossy
            // paraphrase, so a summary that came back as long as the span it
            // replaces (a model that ran on past its output ceiling, or a
            // span too small to compress) buys nothing and costs the original
            // text — and, worse, the caller would swap its backend for a
            // *larger* transcript and record a checkpoint saying so. A fold
            // that fails to shrink therefore falls through to the same
            // shortfall exit the oversized-tail case takes below.
            let tokensAfter = estimatedTokenCount(of: folded.transcript)
            if tokensAfter < tokensBefore {
                return (
                    folded.transcript,
                    CompactionResult(
                        summary: folded.summary,
                        summaryEntryId: folded.summaryEntryId,
                        summaryCut: folded.summaryCut,
                        tokensBefore: tokensBefore,
                        tokensAfter: tokensAfter,
                        stagesApplied: stagesApplied + [Summarization.stageName],
                        protectedTokens: protectedTokenCount(of: folded.transcript, protection: protection)
                    )
                )
            }
        }

        // A deterministic fold that only its protected tool outputs keep over
        // target completes: no stage may remove them, so returning the
        // original would give up the whole fold for content that must stay.
        if let kept = foldKeptOverTarget(
            current, stagesApplied: stagesApplied, tokensBefore: tokensBefore, targetTokens: targetTokens,
            protection: protection)
        {
            return kept
        }

        // Shortfall: every available stage ran and none of them left a
        // transcript worth returning — either the oversized tail (the recency
        // window alone is too big, and nothing may touch it) or a fold that
        // did not shrink the transcript. `current`, and the discarded fold,
        // may be smaller than `transcript`, but the function returns the
        // *original* transcript unchanged, so `tokensAfter` must report
        // `tokensBefore` — the size of what is actually being returned — not
        // the size of an attempt that was thrown away.
        return (transcript, shortfallResult)
    }

    /// Returns `folded` as a completed fold when its protected tool outputs
    /// are what keep it over `targetTokens`, and logs that it ends over its
    /// target. Otherwise returns `nil`.
    ///
    /// The protected outputs keep the fold over target when they alone are
    /// over the target, or when the fold would land under the target without
    /// them. The fold must also have shrunk the transcript.
    ///
    /// - Parameters:
    ///   - folded: The transcript the deterministic stages produced.
    ///   - stagesApplied: The stages that produced it, in order.
    ///   - tokensBefore: The estimated size of the transcript before the fold.
    ///   - targetTokens: The budget's target, in tokens.
    ///   - protection: The host rule, or `nil`.
    /// - Returns: The completed fold and its report, or `nil`.
    private static func foldKeptOverTarget(
        _ folded: Transcript,
        stagesApplied: [String],
        tokensBefore: Int,
        targetTokens: Int,
        protection: ToolOutputProtection?
    ) -> (transcript: Transcript, result: CompactionResult)? {
        let protectedTokens = protectedTokenCount(of: folded, protection: protection)
        let tokensAfter = estimatedTokenCount(of: folded)
        guard protectedTokens > 0, tokensAfter < tokensBefore,
            protectedTokens > targetTokens || tokensAfter - protectedTokens <= targetTokens
        else { return nil }
        compactorLogger.warning(
            """
            a fold ends over its target of \(targetTokens, privacy: .public) tokens at \
            \(tokensAfter, privacy: .public) tokens, because it keeps \(protectedTokens, privacy: .public) \
            tokens of protected tool output
            """
        )
        return (
            folded,
            CompactionResult(
                summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensAfter, stagesApplied: stagesApplied,
                protectedTokens: protectedTokens)
        )
    }

    /// The estimated size, in tokens, of the tool outputs `protection`
    /// protects in `transcript`.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to measure.
    ///   - protection: The host rule, or `nil` to protect nothing.
    /// - Returns: The estimated token count, or `0` when nothing is protected.
    static func protectedTokenCount(of transcript: Transcript, protection: ToolOutputProtection?) -> Int {
        let protectedOutputs = ProtectedToolOutputs(entries: Array(transcript), rule: protection)
            .protectedOutputEntries
        return estimatedTokenCount(of: Transcript(entries: protectedOutputs))
    }

    /// Estimates `transcript`'s size in tokens: the total content byte size of
    /// every entry (``TranscriptEntryPayload/contentByteCount``) divided by
    /// ``charsPerTokenEstimate``. The JSON envelope is not counted.
    ///
    /// - Parameter transcript: The transcript to estimate.
    /// - Returns: The estimated token count.
    package static func estimatedTokenCount(of transcript: Transcript) -> Int {
        let totalBytes = transcript.reduce(into: 0) { total, entry in
            total += contentByteCount(of: entry)
        }
        return estimatedTokenCount(bytes: totalBytes)
    }

    /// Estimates `text`'s size in tokens with the same ratio
    /// ``estimatedTokenCount(of:)`` applies to a transcript.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count.
    package static func estimatedTokenCount(of text: String) -> Int {
        estimatedTokenCount(bytes: text.utf8.count)
    }

    /// Converts a byte count into an estimated token count, rounded up.
    ///
    /// - Parameter bytes: The byte count to convert.
    /// - Returns: The estimated token count.
    private static func estimatedTokenCount(bytes: Int) -> Int {
        Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))
    }

    /// The content byte size of `entry`, measured through its
    /// ``TranscriptEntryPayload`` mirror without the JSON envelope.
    ///
    /// - Parameter entry: The entry to measure.
    /// - Returns: The entry's content size in bytes.
    static func contentByteCount(of entry: Transcript.Entry) -> Int {
        let (_, payload, _) = TranscriptEntryMapper.event(from: entry)
        return payload.contentByteCount
    }
}
