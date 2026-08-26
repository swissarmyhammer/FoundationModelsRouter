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
    public init(
        id: String = ULID.generate().description,
        summary: String?,
        summaryEntryId: String? = nil,
        summarizerModel: String? = nil,
        summaryCut: Bool = false,
        tokensBefore: Int,
        tokensAfter: Int,
        stagesApplied: [String]
    ) {
        self.id = id
        self.summary = summary
        self.summaryEntryId = summaryEntryId
        self.summarizerModel = summarizerModel
        self.summaryCut = summaryCut
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.stagesApplied = stagesApplied
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
            stagesApplied: stagesApplied
        )
    }
}

/// The compaction pipeline. It runs the deterministic stages in order until
/// the transcript lands under ``TokenBudget/target``, then falls back to the
/// model-assisted ``Summarization`` stage when a `summarizer` is supplied.
/// It reports the shortfall when no stage is enough.
public enum Compactor {
    /// The deterministic stages this pipeline runs, in order.
    static let stages: [any CompactionStage] = [ToolOutputElision(), TurnTruncation()]

    /// The characters-per-token ratio ``estimatedTokenCount(of:)`` applies to
    /// a transcript's content bytes.
    static let charsPerTokenEstimate: Double = 4.0

    /// Runs the pipeline over `transcript` and folds it down to at most
    /// `budget.target` of `budget.limit`. The pipeline stops at the first
    /// stage that lands under target. When no stage is enough, the original
    /// transcript is returned unchanged with an empty
    /// ``CompactionResult/stagesApplied``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold.
    ///   - prompt: The compaction prompt ``Summarization`` sends to `summarizer`.
    ///   - budget: The token budget to fold against.
    ///   - summarizer: The model ``Summarization`` calls, or `nil` for the model-free pipeline.
    ///   - summarization: The model-assisted stage and its tuning.
    ///   - pendingRuns: The run-plane summaries of the runs still running, in tracking order.
    /// - Returns: The folded transcript and a report of what happened.
    /// - Throws: What `summarizer.summarize(_:maxTokens:)` throws, or
    ///   ``SummarizationError/emptySummary`` when the summary holds no text.
    public static func compact(
        _ transcript: Transcript,
        prompt: CompactionPrompt = .default,
        budget: TokenBudget,
        summarizer: (any CompactionSummarizer)? = nil,
        summarization: Summarization = Summarization(),
        pendingRuns: [CompactionSegment.PendingRunSummary] = []
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        let tokensBefore = estimatedTokenCount(of: transcript)
        let targetTokens = budget.targetTokens

        // Every exit that returns `transcript` untouched — already under
        // target, and the shortfall at the end — reports the same thing: no
        // stage applied, no summary, and `tokensAfter` naming the size of what
        // is actually being returned. One value, so the two cannot drift.
        let shortfallResult = CompactionResult(
            summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [])

        guard tokensBefore > targetTokens else {
            return (transcript, shortfallResult)
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
            let folded = try await summarization.apply(
                transcript,
                prompt: prompt,
                tokensBefore: tokensBefore,
                priorStagesApplied: stagesApplied,
                summarizer: summarizer,
                pendingRuns: pendingRuns
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
                        stagesApplied: stagesApplied + [Summarization.stageName]
                    )
                )
            }
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
