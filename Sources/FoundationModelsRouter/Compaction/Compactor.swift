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
    /// This fold's own identity — generated once when the result is created,
    /// and stable for the result's whole life.
    ///
    /// A fold has no SDK-given id of its own, so this is a generated ``ULID``
    /// string rather than a source-derived one. It rides inside the
    /// ``SessionEvent/compaction(_:)`` payload, so every consumer of one fold
    /// — two ``SessionProjection``s replaying the same event sequence
    /// included — reads the same id and can key a row on it directly. It is
    /// never a transcript entry id; the synthesized summary entry's id, when
    /// one exists, travels separately as ``summaryEntryId``.
    public let id: String

    /// The synthesized fold summary, or `nil` when no ``Summarization``
    /// ran — either no `summarizer` was supplied to
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` (the model-free
    /// fallback), the deterministic stages alone already landed the
    /// transcript under target, there was no old span left to summarize (the
    /// oversized-tail case), or the fold's own summary left the transcript no
    /// smaller than it was and so was discarded unapplied.
    public let summary: String?

    /// The synthesized summary entry's own `Transcript.Entry.id`, or `nil`
    /// when no summary entry was applied — the join key from this fold back
    /// to the raw transcript and the recording, present exactly when
    /// ``summary`` is.
    public let summaryEntryId: String?

    /// The ``ModelRef`` string of the model that wrote ``summary``, or `nil`
    /// when ``summary`` is `nil` or when the producer did not name one.
    ///
    /// This field is the signal that names the summary's writer.
    /// ``RoutedSessionActor`` sets it on every fold it applies: the profile's
    /// flash slot, or the session's own model — see
    /// ``RoutedSessionActor/performAutoCompaction(prompt:budget:)`` for why a
    /// consumer must be able to see which model summarized. A fold built
    /// outside a session — ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// called bare, or a cold ``SessionProjection`` row seeded from a
    /// persisted checkpoint — carries `nil`, because no model name reaches
    /// those producers.
    public let summarizerModel: String?

    /// The transcript's estimated size, in tokens, before this pipeline ran.
    public let tokensBefore: Int

    /// The transcript's estimated size, in tokens, after this pipeline ran —
    /// equal to ``tokensBefore`` when no stage was applied (already under
    /// target, an oversized recency window made every stage insufficient, or
    /// the fold that ran did not shrink the transcript).
    public let tokensAfter: Int

    /// The stages that actually ran, in order — empty when the transcript
    /// was already under target, or when every stage ran and the original
    /// transcript is returned unchanged anyway: the oversized-tail case, and
    /// a fold whose summary left the transcript no smaller than it was.
    public let stagesApplied: [String]

    /// Creates a compaction result.
    ///
    /// - Parameters:
    ///   - id: This fold's own identity. Defaults to a freshly generated
    ///     ``ULID`` string — see ``id`` for why a fold's identity is
    ///     generated rather than source-derived.
    ///   - summary: The synthesized fold summary, or `nil`.
    ///   - summaryEntryId: The synthesized summary entry's own
    ///     `Transcript.Entry.id`, or `nil` when no summary entry was applied.
    ///     Defaults to `nil`.
    ///   - summarizerModel: The ``ModelRef`` string of the model that wrote
    ///     `summary`, or `nil` when no producer named one. Defaults to `nil`.
    ///   - tokensBefore: The estimated pre-fold size, in tokens.
    ///   - tokensAfter: The estimated post-fold size, in tokens.
    ///   - stagesApplied: The stages that ran, in order.
    public init(
        id: String = ULID.generate().description,
        summary: String?,
        summaryEntryId: String? = nil,
        summarizerModel: String? = nil,
        tokensBefore: Int,
        tokensAfter: Int,
        stagesApplied: [String]
    ) {
        self.id = id
        self.summary = summary
        self.summaryEntryId = summaryEntryId
        self.summarizerModel = summarizerModel
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.stagesApplied = stagesApplied
    }

    /// Returns a copy of this result that names the model that wrote its
    /// summary, or this result unchanged when there is nothing to name.
    ///
    /// A result carries a summarizer name only together with a summary —
    /// see ``summarizerModel`` — so a result with no ``summary`` (a
    /// deterministic-only fold, or a discarded one) returns unchanged, as
    /// does a `nil` `modelName`.
    ///
    /// - Parameter modelName: The ``ModelRef`` string of the model that wrote
    ///   ``summary``, or `nil` when the caller has none to name.
    /// - Returns: The named copy, or `self` when there is nothing to name.
    func withSummarizerModel(_ modelName: String?) -> CompactionResult {
        guard summary != nil, let modelName else { return self }
        return CompactionResult(
            id: id,
            summary: summary,
            summaryEntryId: summaryEntryId,
            summarizerModel: modelName,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            stagesApplied: stagesApplied
        )
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
/// `compact(_:prompt:budget:summarizer:summarization:pendingRuns:)` returns both the folded transcript
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
    /// turn a transcript's content size into a token estimate
    /// (compaction_plan.md §1.5's "prospective size check"), in the absence
    /// of any live model measurement at this layer: `Compactor` is a pure
    /// function over a bare `Transcript`, with no session and no backend to
    /// ask for real usage. `4.0` is the commonly cited average for English
    /// text under BPE-style tokenizers, so what it is applied to must itself
    /// be text a model will actually be shown — never a transcript's on-disk
    /// JSON envelope, which is why ``estimatedTokenCount(of:)`` measures
    /// ``TranscriptEntryPayload/contentByteCount`` rather than the encoded
    /// payload's own size.
    static let charsPerTokenEstimate: Double = 4.0

    /// Runs the pipeline over `transcript`, folding it down to at most
    /// `budget.target` of `budget.limit`.
    ///
    /// Stages run in order (``ToolOutputElision`` first, then
    /// ``TurnTruncation``, then — only when `summarizer` is non-`nil` —
    /// ``Summarization``) and the pipeline stops as soon as one lands the
    /// transcript under target. When the transcript is already under target,
    /// no stage runs. When every deterministic stage runs without success and
    /// no `summarizer` was supplied, ``Summarization`` finds no old span left
    /// to fold (the recency window itself is too large, and no stage may
    /// touch it), or the fold it produced is no smaller than the transcript
    /// it folded — the *original* transcript is returned unchanged
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
    ///   - summarization: The model-assisted stage itself, carrying its own
    ///     tuning: how many newest turns the fold leaves untouched
    ///     (``Summarization/keepRecentTurns``), the estimated-token ceiling a
    ///     single summarizer call's content may reach before the span is
    ///     chunked (``Summarization/maxChunkTokens``), and the share of that
    ///     content a call's answer may occupy
    ///     (``Summarization/summaryTokenRatio``). Defaults to
    ///     `Summarization()` — every knob at its own documented default, which
    ///     is what a caller that does not tune the fold gets. Unused on the
    ///     model-free path, for the same reason `prompt` is.
    ///   - pendingRuns: The run-plane summaries of the runs still parked in
    ///     the calling session's `SessionMailbox` at the moment this fold
    ///     runs, in park order — carried into the synthesized boundary when
    ///     ``Summarization`` runs (see
    ///     ``Summarization/apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:pendingRuns:)``).
    ///     Defaults to empty — the bare-transcript callers with no mailbox —
    ///     which leaves the boundary exactly as before.
    /// - Returns: The folded transcript (unchanged from `transcript` when no
    ///   stage helped enough) and a report of what happened.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, unmodified, when
    ///   ``Summarization`` runs and the summarizer call fails. Also
    ///   ``SummarizationError/emptySummary`` when that call answers with text
    ///   that holds no characters — a fold cannot store a boundary carrying no
    ///   summary, so it is reported rather than applied.
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

    /// Estimates `transcript`'s size in tokens: the total *content* byte size
    /// of every entry (``TranscriptEntryPayload/contentByteCount``, reached via
    /// ``TranscriptEntryMapper``, which maps every entry kind — segments, tool
    /// calls, tool definitions — without throwing), divided by
    /// ``charsPerTokenEstimate``.
    ///
    /// Routing through the payload mapper keeps this estimate honest about
    /// *every* content-bearing field a stage might shrink (segment text,
    /// tool-call arguments, tool names), not just `.text` segments — while
    /// ``TranscriptEntryPayload/contentByteCount`` keeps the payload's own JSON
    /// envelope out of the sum. That distinction is load-bearing, not
    /// cosmetic: this estimate is compared *absolutely* against real token
    /// counts in two places — ``compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// checks it against ``TokenBudget/targetTokens``, and a session's fold
    /// writes ``CompactionResult/tokensAfter`` into
    /// ``RoutedSession/contextFill``'s numerator, where every other writer puts
    /// measured tokenizer counts. Measuring `entryId`s, segment ids, `"type"`
    /// discriminators and JSON punctuation as if a tokenizer would see them
    /// inflated the estimate by roughly 1.8x on a realistic transcript, which
    /// made a fold *raise* measured fill.
    ///
    /// `package` rather than `internal` because the compaction evals state each
    /// seed's foldable span in the SAME estimate a fold is judged by, and they
    /// state it from `FoundationModelsRouterEvalSupport`, a plain package target
    /// that cannot reach `internal` through `@testable`. The `String` overload
    /// below is `package` for the matching reason, stated on it.
    ///
    /// - Parameter transcript: The transcript to estimate.
    /// - Returns: The estimated token count.
    package static func estimatedTokenCount(of transcript: Transcript) -> Int {
        let totalBytes = transcript.reduce(into: 0) { total, entry in
            total += contentByteCount(of: entry)
        }
        return estimatedTokenCount(bytes: totalBytes)
    }

    /// Estimates `text`'s size in tokens using the same
    /// ``charsPerTokenEstimate`` character-ratio ``estimatedTokenCount(of:)``
    /// applies to a whole transcript — shared so a single-string estimate
    /// (e.g. ``ToolOutputCapping``'s tool-output cap, task 1334fk3) is
    /// measured consistently with the transcript-level one.
    ///
    /// `package`, like the transcript overload above and for the same reason:
    /// the plain `FoundationModelsRouterRealModelSupport` target's
    /// `CompactionFold` measures each summarizer answer with it, and a plain
    /// target cannot use `@testable import` (task ^cvsh3m9). `package` stops
    /// at this package's own boundary.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count.
    package static func estimatedTokenCount(of text: String) -> Int {
        estimatedTokenCount(bytes: text.utf8.count)
    }

    /// Converts a raw byte count into an estimated token count via
    /// ``charsPerTokenEstimate``, rounding up — the shared arithmetic both
    /// ``estimatedTokenCount(of:)`` overloads apply to their respective byte
    /// counts (a transcript's total content size, or a single string's UTF-8
    /// size). Rounding once, over the whole sum, is what makes the two
    /// overloads agree exactly on the same text.
    ///
    /// - Parameter bytes: The byte count to convert.
    /// - Returns: The estimated token count.
    private static func estimatedTokenCount(bytes: Int) -> Int {
        Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))
    }

    /// The content byte size of `entry`, measured through its
    /// ``TranscriptEntryPayload`` mirror — every content-bearing field across
    /// every entry kind, and none of the mirror's own JSON envelope (see
    /// ``TranscriptEntryPayload/contentByteCount``).
    ///
    /// - Parameter entry: The entry to measure.
    /// - Returns: The entry's content size in bytes.
    private static func contentByteCount(of entry: Transcript.Entry) -> Int {
        let (_, payload, _) = TranscriptEntryMapper.event(from: entry)
        return payload.contentByteCount
    }
}
