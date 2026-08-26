import Foundation
import FoundationModels

/// A minimal model abstraction the ``Summarization`` stage calls to condense
/// text (compaction_plan.md §1.3 stage 3, §1.4): "an injected summarizer
/// model (default: the session's own model; profile `flash` slot as the
/// documented override)".
///
/// Deliberately narrower than ``LanguageModelSessionBackend``: summarization
/// is a single stateless text-in/text-out call — render a span, ask for its
/// summary — not a multi-turn chat/tool session, so this protocol asks for
/// nothing beyond that one call. A caller wiring a real model in (e.g. a
/// `RoutedSession`'s own backend, or its profile's `flash` slot) adapts it to
/// this shape trivially; a test wires in a scripted fake with none of
/// ``LanguageModelSessionBackend``'s unrelated surface (streaming, tools,
/// forking, transcript/usage introspection) to satisfy.
public protocol CompactionSummarizer: Sendable {
    /// Produces a complete text response to `prompt` — here, always the
    /// compaction instructions plus the span (or batch of chunk summaries)
    /// being condensed (see ``Summarization/apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:pendingRuns:)``).
    ///
    /// `maxTokens` is a real ceiling, not a hint: a fold exists to make a
    /// transcript smaller, and a summarizer left to answer at any length
    /// routinely returns a summary nearly the size of the span it replaces,
    /// which saves a session almost nothing. A conformer that reaches a model
    /// must pass it down to that model's own output limit rather than fall
    /// back to whatever the generation path defaults to. A conformer that
    /// cannot bound its model at all still owes the caller nothing beyond a
    /// best effort: ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// discards a fold that failed to shrink the transcript, so an ignored
    /// ceiling costs a wasted call, never a worse transcript.
    ///
    /// `maxTokens` bounds the whole generation, not the summary text alone. A
    /// reasoning model writes a `<think>` block before its answer, and those
    /// tokens are generated under the same limit. So a fold sizes `maxTokens`
    /// as two amounts added together — what the summary text may occupy
    /// (``Summarization/summaryTokenRatio``) plus what the reasoning before it
    /// may occupy (``Summarization/reasoningTokenHeadroom``) — and a conformer
    /// passes the sum straight down to its model. A conformer that subtracts
    /// from it, or that measures the answer alone against it, takes the
    /// reasoning room away again.
    ///
    /// - Parameters:
    ///   - prompt: The assembled compaction instructions plus content to
    ///     condense.
    ///   - maxTokens: The ceiling, in tokens, on everything this call
    ///     generates — the reasoning and the answer together. See
    ///     ``Summarization/summaryTokenRatio`` and
    ///     ``Summarization/reasoningTokenHeadroom`` for how a fold sizes it.
    /// - Returns: The model's complete text response.
    /// - Throws: If summarization fails.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String
}

/// A failure of the model-assisted ``Summarization`` stage that the summarizer
/// itself did not raise.
public enum SummarizationError: Error, Equatable, LocalizedError {
    /// A summarizer call returned successfully and its answer held no text —
    /// it was empty, or it was whitespace alone.
    ///
    /// This is a fold failure, not a summary that lost content. A fold replaces
    /// a span of real conversation with the text it stores, so a boundary that
    /// carries no text erases that span and gives the resumed session nothing
    /// to read. It is reported rather than stored, so the caller can degrade —
    /// `RoutedSessionActor.performAutoCompaction(prompt:budget:)` falls through
    /// to its next summarizer tier, and then to the deterministic pipeline,
    /// exactly as it does for a summarizer that throws.
    ///
    /// A reasoning model produces this answer when its output ceiling has room
    /// for the summary text alone: the `<think>` block spends the whole
    /// ceiling, generation stops inside the reasoning, and the turn records an
    /// empty response. ``Summarization/reasoningTokenHeadroom`` is what keeps
    /// that ceiling wide enough.
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .emptySummary:
            return "the summarizer returned no text, so the fold has no summary to store"
        }
    }
}

/// The model-assisted compaction stage (compaction_plan.md §1.3 stage 3):
/// renders the folded span to text, summarizes it with a ``CompactionPrompt``
/// via an injected ``CompactionSummarizer``, and synthesizes the summary
/// entry — a `.response` carrying the summary text plus its
/// ``CompactionSegment``.
///
/// Unlike ``ToolOutputElision``/``TurnTruncation``, this does **not** conform
/// to ``CompactionStage``: it is async (it calls a model) and needs a prompt
/// and a summarizer, neither of which that synchronous, dependency-free
/// protocol accepts (see ``CompactionStage``'s own doc comment). Instead,
/// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` invokes it directly as
/// the pipeline's last resort, once the deterministic stages alone don't land
/// the transcript under target.
///
/// That call takes the stage itself, so the three knobs below are the
/// pipeline's own tuning rather than settings only a direct caller of
/// ``apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:pendingRuns:)``
/// can reach: a caller with a different model or a different tolerance for
/// compression hands `compact` a configured instance, and one that has no
/// opinion gets `Summarization()` — every default below — by omitting it.
///
/// Always operates on the **original** transcript passed to it, never on a
/// partially-folded intermediate: by the time the deterministic stages have
/// both run without success, ``TurnTruncation`` has already dropped the old
/// turns' *content* from its own output — there would be nothing left to
/// render. Recomputing the old/recent split from scratch (via
/// ``TranscriptTurns``, the same shared partitioning every stage uses) keeps
/// this stage self-sufficient and keeps the recency window byte-identical to
/// what the other stages would have kept.
public struct Summarization: Sendable, Equatable, Codable {
    /// This stage's name, recorded in ``CompactionResult/stagesApplied`` and
    /// ``CompactionSegment/Content/stagesApplied``.
    public static let stageName = "Summarization"

    /// How many of the newest turns are the untouchable recency window.
    ///
    /// Defaults to `4` (compaction_plan.md §1.3), matching
    /// ``ToolOutputElision``/``TurnTruncation``'s own default so every stage
    /// agrees on where the recency window starts.
    public var keepRecentTurns: Int

    /// The estimated-token ceiling (``Compactor/estimatedTokenCount(of:)``'s
    /// character-ratio estimate) a single summarizer call's rendered content
    /// may reach before the folded span is split into multiple chunks,
    /// summarized independently (map), and their summaries re-summarized
    /// (reduce) into one final summary.
    ///
    /// The reduce step itself re-chunks and re-reduces when the chunk
    /// summaries themselves would exceed this in one call (see
    /// ``reduce(_:prompt:summarizer:)``), so the chunking applies at every
    /// level of the map-reduce tree, not just the first.
    ///
    /// It is a chunking target, not a promise about what any one call ingests.
    /// Both packers here — ``chunk(_:maxTokens:)`` over turns and
    /// ``chunkStrings(_:maxTokens:)`` over prior summaries — share
    /// ``binPack(_:maxTokens:tokens:)``, which never splits a single item, so
    /// an item already larger than this becomes its own oversized group and is
    /// condensed as it stands; and ``reduce(_:prompt:summarizer:)``'s
    /// no-progress fallback deliberately hands one call everything left. Those
    /// are examples of a call ingesting more than this, not a complete list of
    /// them. What holds for *every* call regardless is the output bound:
    /// ``maximumSummaryTokens`` caps what any one call's summary text may
    /// occupy, however much it was handed.
    public var maxChunkTokens: Int

    /// The fraction of a full ``maxChunkTokens`` of content that sizes
    /// ``maximumSummaryTokens`` — the cap on every call's stated budget and
    /// summary allowance, and through them the bound on the final summary of
    /// a conversation of any length.
    ///
    /// Defaults to `0.25`, and since task ^xx02yn6 it sizes the CAP alone.
    /// The per-call ask is ``statedBudgetShareOfContent`` of the call's own
    /// content — stated to the model in the assembled prompt — and the
    /// generation allowance follows that ask (see
    /// ``statedBudgetShareOfContent`` for the measurements). This ratio's job
    /// is the one a per-call share cannot do: a call can be handed more than
    /// ``maxChunkTokens`` (see that property — neither packer splits a single
    /// item), and any share of *that* grows with the span.
    /// ``maximumSummaryTokens`` closes it without having to know which calls
    /// those are: it caps every call's stated budget at what a full
    /// ``maxChunkTokens`` of content earns at this ratio, so the bound holds
    /// for every call a fold makes, and therefore for the final summary of a
    /// span of any length.
    public var summaryTokenRatio: Double

    /// The tokens, in addition to the summary allowance, every summarizer call
    /// is given for the reasoning a model writes before its answer.
    ///
    /// Defaults to `8192`. The two amounts are added rather than shared,
    /// because they scale with different things. The summary allowance scales
    /// with the content, which is what ``summaryTokenRatio`` states. The
    /// reasoning does not: how much a model thinks before it answers is a
    /// property of the model, not of the span, so taking a fraction of a small
    /// span would leave a reasoning model no room at all while a large span
    /// would hand it more than it can use. A fixed amount beside the fraction
    /// says exactly that.
    ///
    /// Measurement gives the default, and it is this repository's own, twice
    /// over. `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift`
    /// records that the gated model always writes a `<think>` block first,
    /// that a ceiling of `512` leaves the response empty, and that `4096` did
    /// not — the old default. The instrumented Qwen3.8-27B probe of
    /// 2026-08-20 (task ^xx02yn6) then measured `4096` failing too, once the
    /// assembled prompt began stating a size budget: the model deliberated
    /// over the budget inside `<think>`, spent the whole `4224`-token ceiling
    /// there, and answered EMPTY on 2 of 2 probe seeds. Doubling the headroom
    /// is what gives that longer deliberation room to reach the answer.
    ///
    /// It is a ceiling, not a target. Generation still stops at the model's
    /// end-of-sequence token, so a model that reasons briefly, or not at all,
    /// pays only for the tokens it writes. The bound a fold cares about stays
    /// on the summary text: this amount is never summary text, and
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// discards any fold that failed to shrink the transcript regardless.
    public var reasoningTokenHeadroom: Int

    /// The floor, in tokens, no call's summary allowance is squeezed below —
    /// `128`, roughly a few dense sentences.
    ///
    /// ``summaryTokenRatio`` alone would hand a small span an allowance too
    /// tight to say anything in, and a generation cut off mid-sentence is worse
    /// than a slightly larger one: the ceiling is a hard stop, not a target the
    /// model aims at. A fold that still fails to shrink the transcript is
    /// caught where it should be —
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` returns
    /// the original transcript rather than apply it.
    public static let minimumSummaryTokens = 128

    /// The bytes the whole boundary text — the final summary plus any
    /// pending-runs rendering — must stay UNDER the folded span's own content
    /// bytes for the fold to strictly shrink the transcript.
    ///
    /// ``Compactor/estimatedTokenCount(of:)-(Transcript)`` sums content bytes
    /// over the whole transcript and divides once by
    /// ``Compactor/charsPerTokenEstimate``, rounding up. A drop of one full
    /// character-per-token ratio in the byte sum therefore always drops the
    /// rounded estimate by at least one token, which is what
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``'s
    /// did-not-shrink guard requires — a drop smaller than this can round
    /// away to nothing and leave the guard discarding a fold whose bytes did
    /// shrink.
    public static let shrinkMarginBytes = Int(Compactor.charsPerTokenEstimate)

    /// The estimated UTF-8 size of one English word with its separator, used
    /// to state a byte budget to the model as a word count.
    ///
    /// The budget is enforced in bytes (``summaryByteBudget(forSpanBytes:pendingRunsRenderingBytes:)``)
    /// because bytes are what the shrink guard measures, and stated in words
    /// because a model tracks its own length in words far better than in
    /// bytes or characters. Five letters plus a space is the commonly cited
    /// average for English text, so a budget stated at this rate slightly
    /// under-asks — the safe direction, since text past the byte budget is
    /// cut.
    public static let summaryBytesPerWordEstimate = 6.0

    /// The share of a call's own content its STATED size budget names — the
    /// number the assembled prompt asks the model for, sitting under the span
    /// byte budget the fold enforces.
    ///
    /// A share of the content rather than the compression allowance, and the
    /// instrumented Qwen3.8-27B probes of 2026-08-20 (task ^xx02yn6) measured
    /// why. The allowance-derived target — 85 words for the probe seeds —
    /// cannot hold eight sections of verbatim facts, and the thinking model
    /// spent whole 4224- and then 8320-token ceilings inside `<think>`
    /// drafting, word-counting and redrafting against it, answering EMPTY on
    /// 2 of 2 seeds both times. The share sits well under the enforced bound
    /// while staying near the model's natural answer, so compliance costs it
    /// a trim rather than an optimisation.
    ///
    /// `0.75` is the measured-best value of the two the probe compared. At
    /// `0.75` both probe seeds stored the fact (one paid a condense re-ask
    /// and a recorded cut after overshooting the enforced budget by 26
    /// bytes). At `0.6` — tried to remove that overshoot — the tighter
    /// number re-triggered the think spiral on `encryption-algorithm` under
    /// greedy decoding and the answer came back EMPTY, so the wider target
    /// stands.
    public static let statedBudgetShareOfContent = 0.75

    /// Creates a summarization stage.
    ///
    /// - Parameters:
    ///   - keepRecentTurns: How many of the newest turns to leave untouched.
    ///     Defaults to `4`.
    ///   - maxChunkTokens: The estimated-token ceiling per summarizer call
    ///     before chunking kicks in. Defaults to `2000`.
    ///   - summaryTokenRatio: The fraction of the content it condenses a
    ///     single summarizer call's summary text may occupy. Defaults to
    ///     `0.25`.
    ///   - reasoningTokenHeadroom: The tokens every call is given on top of
    ///     that allowance, for the reasoning a model writes before its answer.
    ///     Defaults to `8192`.
    public init(
        keepRecentTurns: Int = 4,
        maxChunkTokens: Int = 2000,
        summaryTokenRatio: Double = 0.25,
        reasoningTokenHeadroom: Int = 8192
    ) {
        self.keepRecentTurns = keepRecentTurns
        self.maxChunkTokens = maxChunkTokens
        self.summaryTokenRatio = summaryTokenRatio
        self.reasoningTokenHeadroom = reasoningTokenHeadroom
    }

    /// What folding `transcript` down to a summary produced: the resulting
    /// transcript (header, synthesized summary entry, untouched recency
    /// window) and the summary text alone (for ``CompactionResult/summary``).
    public struct Folded: Sendable, Equatable {
        /// The folded transcript: the header, the synthesized summary entry,
        /// then the untouched recency window.
        public let transcript: Transcript

        /// The synthesized summary text, alone — the same text the
        /// transcript's summary entry carries in its `.text` segment.
        public let summary: String

        /// The synthesized summary entry's own `Transcript.Entry.id` — the
        /// join key ``CompactionResult/summaryEntryId`` carries from the fold
        /// back to the raw transcript and the recording.
        public let summaryEntryId: String

        /// Whether the last-resort cut removed text from ``summary`` before
        /// the fold stored it — carried into
        /// ``CompactionResult/summaryCut`` so the fold's report records when
        /// the trim fired (task ^xx02yn6). See that property for what a
        /// `true` means for the stored text.
        public let summaryCut: Bool
    }

    /// Folds `transcript`'s old span (everything but the header and the
    /// newest ``keepRecentTurns`` turns) into a single synthesized summary
    /// entry, via `summarizer`.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold. Always the *original*
    ///     transcript given to ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``,
    ///     never an already-truncated intermediate (see this type's own doc
    ///     comment).
    ///   - prompt: The compaction prompt sent to `summarizer` verbatim, ahead
    ///     of the rendered content, for every summarizer call this fold
    ///     makes (map and reduce alike). Its ``CompactionPrompt/name`` lands
    ///     in the resulting ``CompactionSegment``.
    ///   - tokensBefore: The whole pipeline's measured/estimated size before
    ///     any stage ran — carried into the resulting ``CompactionSegment``
    ///     unchanged, matching ``CompactionResult/tokensBefore``.
    ///   - priorStagesApplied: The deterministic stages
    ///     ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` already
    ///     attempted before falling back to this stage (e.g.
    ///     `["ToolOutputElision", "TurnTruncation"]`) — this stage's own
    ///     ``stageName`` is appended to produce the resulting
    ///     ``CompactionSegment/Content/stagesApplied``.
    ///   - summarizer: The model called to condense text.
    ///   - pendingRuns: The run-plane summaries of the runs still running in
    ///     the session's `SessionMailbox` at the moment this boundary is
    ///     written, in tracking order. When non-empty they land in the resulting
    ///     ``CompactionSegment/Content/pendingRuns`` and as an additional
    ///     model-visible text segment on the summary entry
    ///     (``CompactionSegment/renderedPendingRuns(_:)``), and the
    ///     rendering's bytes are charged against the span byte budget the
    ///     final summary must fit — see
    ///     ``summaryByteBudget(forSpanBytes:pendingRunsRenderingBytes:)``
    ///     (tasks ^64f3hnv, ^xx02yn6).
    ///     When empty — the default, and always the case for the bare-session
    ///     recipe, which has no mailbox — the boundary is exactly as before.
    /// - Returns: The folded transcript and summary text, or `nil` when there
    ///   is no old span to fold (every turn is inside the recency window) —
    ///   the same "oversized tail" case the deterministic stages report as a
    ///   shortfall, since summarizing nothing cannot help either.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, unmodified — a
    ///   summarizer failure is a real error, never silently swallowed into a
    ///   degraded result. Also ``SummarizationError/emptySummary`` when a
    ///   summarizer call returns text that holds no characters: a boundary
    ///   carrying no summary is a fold failure, so it is reported here rather
    ///   than stored (see that case).
    public func apply(
        _ transcript: Transcript,
        prompt: CompactionPrompt,
        tokensBefore: Int,
        priorStagesApplied: [String],
        summarizer: any CompactionSummarizer,
        pendingRuns: [CompactionSegment.PendingRunSummary] = []
    ) async throws -> Folded? {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (old, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        guard !old.isEmpty else { return nil }

        let answeredSummary = try await summarize(old, prompt: prompt, summarizer: summarizer)
        let spanBytes = old.flatMap(\.entries).reduce(0) { $0 + Compactor.contentByteCount(of: $1) }
        let renderingBytes =
            pendingRuns.isEmpty ? 0 : CompactionSegment.renderedPendingRuns(pendingRuns).utf8.count
        let budgetBytes = Self.summaryByteBudget(
            forSpanBytes: spanBytes, pendingRunsRenderingBytes: renderingBytes)
        let (summaryText, summaryCut) = try await resolveOversizedSummary(
            answeredSummary, within: budgetBytes, summarizer: summarizer)

        let entryId = "compaction-summary-\(UUID().uuidString)"
        let foldedEntryIds = old.flatMap(\.entries).map(\.id)
        let recentEntries = recent.flatMap(\.entries)
        let stagesApplied = priorStagesApplied + [Self.stageName]
        let liveWindowEntryIds = header.map(\.id) + [entryId] + recentEntries.map(\.id)

        // The entry construction itself is shared with the deterministic-only
        // fold path — see ``CompactionSegment/boundaryEntry(id:summaryText:content:)``.
        func makeSummaryEntry(tokensAfter: Int) -> Transcript.Entry {
            CompactionSegment.boundaryEntry(
                id: entryId,
                summaryText: summaryText,
                content: CompactionSegment.Content(
                    liveWindowEntryIds: liveWindowEntryIds,
                    foldedEntryIds: foldedEntryIds,
                    tokensBefore: tokensBefore,
                    tokensAfter: tokensAfter,
                    stagesApplied: stagesApplied,
                    promptName: prompt.name,
                    pendingRuns: pendingRuns.isEmpty ? nil : pendingRuns
                )
            )
        }

        // tokensAfter measures the *resulting* transcript, including the
        // synthesized entry itself — a two-pass build (placeholder, then
        // corrected) rather than an approximation that omits the entry's own
        // contribution to the final size.
        let provisional = Transcript(entries: header + [makeSummaryEntry(tokensAfter: 0)] + recentEntries)
        let tokensAfter = Compactor.estimatedTokenCount(of: provisional)
        let finalTranscript = Transcript(entries: header + [makeSummaryEntry(tokensAfter: tokensAfter)] + recentEntries)

        return Folded(
            transcript: finalTranscript, summary: summaryText, summaryEntryId: entryId,
            summaryCut: summaryCut)
    }

    /// The bytes the fold's FINAL summary may occupy for the boundary entry
    /// to strictly shrink the transcript: the folded span's own content
    /// bytes, minus ``shrinkMarginBytes``, minus the pending-runs rendering
    /// that shares the boundary entry (task ^xx02yn6).
    ///
    /// This is the ONE size bound the stored summary is held to, and it is
    /// the invariant's own arithmetic rather than a ratio of anything: the
    /// did-not-shrink guard in
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// compares the whole folded transcript against the original, the two
    /// differ exactly by the boundary entry against the span, and the
    /// boundary entry's content bytes are the summary text plus the rendering
    /// (the structure segment counts zero — see
    /// ``TranscriptEntryPayload/contentByteCount``). The 2-seed Qwen probe of
    /// 2026-08-20 measured what a stricter, ratio-based bound cost: both raw
    /// answers carried the planted fact verbatim, and the ratio cut stored
    /// the `1. Intent` line alone.
    ///
    /// Zero or below when the rendering alone spends the span:
    /// ``resolveOversizedSummary(_:within:summarizer:)`` then skips the
    /// condense pass — no rewrite of any length could fit — and the guard
    /// discards the fold, which is the safe failure.
    ///
    /// - Parameters:
    ///   - spanBytes: The folded span's content bytes, summed with
    ///     ``Compactor/contentByteCount(of:)`` — the same measure the guard
    ///     reads.
    ///   - renderingBytes: The pending-runs rendering's UTF-8 size, `0` when
    ///     the fold carries no runs.
    /// - Returns: The budget, in UTF-8 bytes — possibly zero or negative.
    static func summaryByteBudget(forSpanBytes spanBytes: Int, pendingRunsRenderingBytes renderingBytes: Int) -> Int {
        spanBytes - shrinkMarginBytes - renderingBytes
    }

    /// Resolves a final summary that may overrun `budgetBytes` into the text
    /// the fold stores, preferring recovery over destruction (task ^xx02yn6):
    ///
    /// 1. A summary already inside the budget is stored word for word —
    ///    however far over the compression target it is, because the budget
    ///    is the shrink invariant and nothing else.
    /// 2. An oversized summary earns ONE condense re-ask: the model is shown
    ///    its own summary and the budget, and a condensed answer that fits is
    ///    stored word for word.
    /// 3. Only then does ``cut(_:toCharacters:)`` fire, over the smaller of
    ///    the two candidates, and the fold records that it fired.
    ///
    /// A budget of zero or below skips the condense re-ask — no rewrite of
    /// any length could fit — and the cut's own zero-budget fallback returns
    /// the summary unchanged for the did-not-shrink guard to discard.
    ///
    /// - Parameters:
    ///   - summary: The fold's final summary, as the model wrote it.
    ///   - budgetBytes: The bytes the stored summary may occupy, from
    ///     ``summaryByteBudget(forSpanBytes:pendingRunsRenderingBytes:)``.
    ///   - summarizer: The model asked to condense its own summary.
    /// - Returns: The text to store, and whether the cut removed text from
    ///   it.
    /// - Throws: Whatever the condense re-ask's
    ///   `summarizer.summarize(_:maxTokens:)` throws, unmodified — the same
    ///   contract every other summarizer call in this fold has.
    private func resolveOversizedSummary(
        _ summary: String,
        within budgetBytes: Int,
        summarizer: any CompactionSummarizer
    ) async throws -> (text: String, cut: Bool) {
        guard summary.utf8.count > budgetBytes else { return (summary, false) }

        var candidate = summary
        if budgetBytes > 0 {
            let condensed = try await condense(summary, toBytes: budgetBytes, summarizer: summarizer)
            if let condensed {
                if condensed.utf8.count <= budgetBytes { return (condensed, false) }
                if condensed.utf8.count < candidate.utf8.count { candidate = condensed }
            }
        }
        let stored = Self.cut(candidate, toCharacters: budgetBytes)
        return (stored, stored.utf8.count < candidate.utf8.count)
    }

    /// Asks `summarizer` once to condense its own oversized `summary` to fit
    /// `budgetBytes` — the recovery step between accepting an answer whole
    /// and cutting it by position.
    ///
    /// The call's generation ceiling is sized from the budget itself
    /// (floored at ``minimumSummaryTokens``, capped at
    /// ``maximumSummaryTokens``) plus ``reasoningTokenHeadroom``, the same
    /// two-amount shape every other summarizer call here generates under.
    ///
    /// - Parameters:
    ///   - summary: The oversized summary to condense.
    ///   - budgetBytes: The bytes the condensed summary should fit. Positive —
    ///     the caller skips this call otherwise.
    ///   - summarizer: The model to re-ask.
    /// - Returns: The condensed answer, or `nil` when the model answered no
    ///   text — the caller then falls back to the cut rather than store or
    ///   report an empty recovery.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws,
    ///   unmodified.
    private func condense(
        _ summary: String,
        toBytes budgetBytes: Int,
        summarizer: any CompactionSummarizer
    ) async throws -> String? {
        let allowance = min(
            maximumSummaryTokens,
            max(Self.minimumSummaryTokens, Int(Double(budgetBytes) / Compactor.charsPerTokenEstimate)))
        let answer = try await summarizer.summarize(
            Self.makeCondensePrompt(summary: summary, budgetBytes: budgetBytes),
            maxTokens: outputTokenCeiling(forSummaryAllowance: allowance)
        )
        return answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : answer
    }

    /// Assembles the condense re-ask's prompt: the rewrite instruction with
    /// the budget stated in words, then the oversized summary, in the same
    /// "instructions, then the thing to condense" shape every fold call uses.
    ///
    /// The instruction demands verbatim values for the same measured reason
    /// ``CompactionPrompt/default`` does: a condense pass that paraphrases a
    /// value loses the fact the fold exists to carry.
    ///
    /// - Parameters:
    ///   - summary: The oversized summary to condense.
    ///   - budgetBytes: The bytes the condensed summary should fit.
    /// - Returns: The assembled prompt.
    static func makeCondensePrompt(summary: String, budgetBytes: Int) -> String {
        """
        The summary below is too long to store. Rewrite it to about \
        \(summaryBudgetWords(forBytes: budgetBytes)) words — a rough ceiling; never \
        count or verify the length. Keep the numbered section structure. Keep every \
        name, identifier, code, number, path and value EXACTLY as written — drop \
        whole sentences before you shorten any stated value.

        ---

        \(summary)
        """
    }

    /// Converts a byte budget into the word count the model is told, at
    /// ``summaryBytesPerWordEstimate`` — never below one word, so a tiny
    /// positive budget still states a real target.
    ///
    /// - Parameter bytes: The budget, in UTF-8 bytes.
    /// - Returns: The word count to state.
    static func summaryBudgetWords(forBytes bytes: Int) -> Int {
        max(1, Int(Double(bytes) / summaryBytesPerWordEstimate))
    }

    // MARK: - Map-reduce summarization

    /// Summarizes `turns` (the folded span), chunking when the rendered
    /// content would exceed ``maxChunkTokens`` in a single summarizer call.
    ///
    /// A short span (rendered content within ``maxChunkTokens``) needs a
    /// single summarizer call. A long span is split into turn-aligned chunks
    /// (``chunk(_:maxTokens:)`` — never splitting a turn), each summarized
    /// independently (map), and the chunk summaries are combined by
    /// ``reduce(_:prompt:summarizer:)`` into the final summary.
    private func summarize(
        _ turns: [TranscriptTurn],
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        let chunks = Self.chunk(turns, maxTokens: maxChunkTokens)
        guard chunks.count > 1 else {
            return try await summarizeOnce(Self.render(chunks[0]), prompt: prompt, summarizer: summarizer)
        }

        var chunkSummaries: [String] = []
        // Serial deliberately: a fold's cancellability depends on it, and on more
        // than this file — see ``summarizeOnce(_:prompt:summarizer:)``.
        for chunk in chunks {
            chunkSummaries.append(try await summarizeOnce(Self.render(chunk), prompt: prompt, summarizer: summarizer))
        }
        return try await reduce(chunkSummaries, prompt: prompt, summarizer: summarizer)
    }

    /// Combines `summaries` (the map step's chunk summaries) into one final
    /// summary — the map-reduce "reduce" step — recursing when the joined
    /// summaries would themselves exceed ``maxChunkTokens`` in a single
    /// summarizer call, so a round re-chunks rather than hand one call
    /// everything, however many chunks the original span needed.
    ///
    /// Re-chunking aims each call at ``maxChunkTokens`` without guaranteeing
    /// it. ``chunkStrings(_:maxTokens:)`` never splits a single summary, so a
    /// summary already over the ceiling becomes its own oversized group and is
    /// condensed as it stands — which can happen in a round that groups and
    /// recurses, not only in the no-progress fallback below, where one call
    /// deliberately takes everything left. The bound that matters does not
    /// turn on which rounds those are: every call here goes through
    /// ``summarizeOnce(_:prompt:summarizer:)``, whose summary allowance is
    /// clamped to ``maximumSummaryTokens``, so no round's summary grows with
    /// the span however much that round ingests.
    ///
    /// When the joined `summaries` don't fit, they are grouped into
    /// turn-aligned-style batches via ``chunkStrings(_:maxTokens:)`` (never
    /// splitting a single summary), each batch is condensed into one new
    /// summary (another map round), and ``reduce(_:prompt:summarizer:)``
    /// recurses on that smaller set — a tree-shaped reduce rather than one
    /// flat pass. Recursion is guaranteed to terminate: each successful
    /// recursive call strictly reduces the summary count (`chunkStrings`
    /// groups strictly fewer than it was given whenever grouping merges at
    /// least two summaries into one), and the one case where grouping cannot
    /// make progress — no two adjacent summaries fit together under
    /// ``maxChunkTokens`` (always true when every summary is individually at
    /// or over the ceiling, but also possible with several under-ceiling
    /// summaries that simply don't pair up), so `chunkStrings` produces one
    /// singleton group per summary — falls back to a single flat reduce
    /// instead of recursing forever.
    ///
    /// - Parameters:
    ///   - summaries: The summaries to combine, in order.
    ///   - prompt: The compaction prompt sent to `summarizer` verbatim.
    ///   - summarizer: The model called to condense text.
    /// - Returns: The final, single combined summary.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, unmodified.
    private func reduce(
        _ summaries: [String],
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        guard summaries.count > 1 else { return summaries[0] }

        let joined = summaries.joined(separator: "\n\n")
        guard Self.estimatedTokens(of: joined) > maxChunkTokens else {
            return try await summarizeOnce(joined, prompt: prompt, summarizer: summarizer)
        }

        let groups = Self.chunkStrings(summaries, maxTokens: maxChunkTokens)
        guard groups.count < summaries.count else {
            // No progress possible: grouping produced one singleton group per
            // summary, so no two adjacent summaries fit together under
            // maxChunkTokens. Recursing further would never terminate —
            // a single flat reduce, over budget or not, is the only option
            // left. Over budget on its *input* only: this call's summary
            // allowance is still capped at `maximumSummaryTokens`, so a span
            // shaped this way cannot buy a final summary that grows with it.
            return try await summarizeOnce(joined, prompt: prompt, summarizer: summarizer)
        }

        var nextRound: [String] = []
        // Serial deliberately, for the reason the map loop in
        // ``summarize(_:prompt:summarizer:)`` is — see ``summarizeOnce(_:prompt:summarizer:)``.
        for group in groups {
            nextRound.append(
                try await summarizeOnce(group.joined(separator: "\n\n"), prompt: prompt, summarizer: summarizer))
        }
        return try await reduce(nextRound, prompt: prompt, summarizer: summarizer)
    }

    /// Assembles `prompt`'s instructions and `content` into one summarizer
    /// call, used identically for a map call (rendering one chunk of turns)
    /// and every reduce-round call (joining prior summaries) — the same
    /// "instructions, then the thing to condense" shape throughout.
    ///
    /// The calls one fold makes through here must stay **serial**, and the reason
    /// lives outside this file: a session folding its own transcript hands
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` a `summarizer` that
    /// registers each call as that turn's one in-flight model call, which is what
    /// lets a client stop interrupt a fold already under way rather than wait it out (see
    /// Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift). Only one call can be
    /// registered at a time, so summarizing chunks — or reduce-round groups —
    /// concurrently would leave every call but the last-registered one unreachable by
    /// the session's own stop primitive. (A caller cancelling its enclosing task would
    /// still reach each of them, so the exposure is specific to that primitive, not to
    /// cancellation in general.) Parallelize either loop above only together with that
    /// registration.
    ///
    /// Every call made through here generates under
    /// ``outputTokenCeiling(forSummaryAllowance:)``, whose summary allowance
    /// is never larger than ``maximumSummaryTokens`` however much content the
    /// call was handed — and that same allowance is STATED to the model, as a
    /// word count between the instructions and the content (task ^xx02yn6).
    /// The ceiling covers the reasoning and the answer together (see
    /// ``reasoningTokenHeadroom``), so it cannot bound the answer alone; the
    /// stated budget is what aims the answer, and the fold's final summary is
    /// then held to the span byte budget in
    /// ``resolveOversizedSummary(_:within:summarizer:)`` — never to a
    /// per-call ratio of the content, which is the arithmetic the 2-seed Qwen
    /// probe of 2026-08-20 measured discarding verbatim facts by position.
    ///
    /// (`^azd033m` measured a HARD stated bound — "write at most N
    /// characters ... Compress hard" — driving Muse-Glimmer to spend its
    /// whole ceiling inside `<think>`. That measurement was that model's;
    /// the standard model is Qwen3.8-27B now, and the budget here is a
    /// target in words, re-measured on the 2-seed probe rather than
    /// inherited.)
    ///
    /// Every call is also checked here, and one answer is refused: text that
    /// holds no characters. A fold stores what a summarizer answers, so a
    /// boundary carrying no text erases the span it replaced and leaves the
    /// resumed session nothing to read. That is a fold failure, and
    /// ``SummarizationError/emptySummary`` reports it. The check stands here
    /// rather than at each call site because every call of a fold — the map
    /// calls and every reduce round alike — is made through this one method.
    ///
    /// - Parameters:
    ///   - content: The content this call condenses — a rendered chunk of
    ///     turns, or a batch of prior summaries.
    ///   - prompt: The compaction prompt sent to `summarizer` verbatim.
    ///   - summarizer: The model called to condense text.
    /// - Returns: The summarizer's answer, exactly as the model wrote it.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws,
    ///   unmodified, or ``SummarizationError/emptySummary`` when that answer
    ///   holds no characters.
    private func summarizeOnce(
        _ content: String,
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        let allowance = summaryTokenAllowance(condensing: content)
        let budgetWords = Self.summaryBudgetWords(forBytes: statedBudgetBytes(condensing: content))
        // "about N words ... never count": the instrumented Qwen probe of
        // 2026-08-20 captured the thinking model counting its draft word by
        // word against the stated target and spending the whole ceiling on
        // the verification, so the line forbids it outright as its own rule —
        // see ``statedBudgetShareOfContent`` for the target's own sizing.
        let summary = try await summarizer.summarize(
            "\(prompt.text)\n\nSize budget: about \(budgetWords) words. "
                + "This is a rough ceiling — never count or verify the length; a near miss is fine."
                + "\n\n---\n\n\(content)",
            maxTokens: outputTokenCeiling(forSummaryAllowance: allowance)
        )
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.emptySummary
        }
        return summary
    }

    /// The characters that end a sentence, and so mark a place a summary can be
    /// cut without ending it mid-thought.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// `summary`, cut down to at most `limit` characters at the last sentence
    /// or list-item boundary that fits inside them.
    ///
    /// This is the LAST RESORT of the recovery ladder
    /// ``resolveOversizedSummary(_:within:summarizer:)`` runs, and its one
    /// caller: it fires only when the fold would otherwise fail to shrink the
    /// transcript — the answer overran the span byte budget and the condense
    /// re-ask did not bring it inside — and the fold records that it fired
    /// (``Folded/summaryCut``). It stays in code rather than being left to
    /// the model because it holds whatever the model writes: it makes "the
    /// boundary entry is smaller than the span it replaces" a property of
    /// this file rather than a hope about a generation.
    ///
    /// It keeps a PREFIX, so it is content-blind — it keeps what the model
    /// said first and drops what it said last, a fact discarded by position
    /// rather than by meaning. That destructiveness is why it is the last
    /// resort and never the compression device: the compression a fold is run
    /// for is asked of the model — the stated budget in
    /// ``summarizeOnce(_:prompt:summarizer:)`` and the generation ceiling —
    /// and `limit` is the shrink invariant's own arithmetic
    /// (``summaryByteBudget(forSpanBytes:pendingRunsRenderingBytes:)``),
    /// never a ratio of the call's content. The 2-seed Qwen probe of
    /// 2026-08-20 (task ^xx02yn6) measured what a ratio-based routine cut
    /// cost: both raw answers carried the planted fact verbatim, and the cut
    /// stored the `1. Intent` line alone.
    ///
    /// `limit` is in the unit
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// really measures — UTF-8 content bytes — so the size cut to here and the
    /// size the did-not-shrink guard reads are the same number. (Bytes and
    /// characters part company on non-ASCII text, and the byte count is the one
    /// that binds, which cuts a little shorter rather than a little longer.)
    ///
    /// The cut falls on a boundary rather than on the byte the budget runs out
    /// on, because a summary is what a resumed session READS. Four fallbacks,
    /// in order, and the last one is what keeps the result non-empty:
    ///
    /// 1. The last SECTION boundary inside the budget, when the text carries a
    ///    numbered-section scaffold — see
    ///    ``sectionAlignedPrefix(of:withinBytes:)``.
    /// 2. Failing that, the last sentence terminator or line end inside the
    ///    budget.
    /// 3. Failing that, the last word boundary inside it.
    /// 4. Failing that, the budget itself.
    ///
    /// The section boundary stands first because of what `^51e9dyq` measured:
    /// ``CompactionPrompt/default`` scaffolds eight numbered sections, and a
    /// sentence-boundary cut stored a scaffold that stops in the middle of a
    /// section. The session model that read the truncated scaffold as its
    /// context degenerated on its next turn — one word repeated to the token
    /// ceiling. Whole sections the model finished are better context than
    /// more bytes of a structure it did not.
    ///
    /// The section cut declines rather than empties: when not even the first
    /// section fits whole, the sentence-boundary cut takes over and the
    /// stored summary ends at a finished sentence inside an unfinished
    /// section. That trade is taken because the only alternatives are an
    /// emptied summary, which is the `^bgxtdk3` defect, or an unbounded one,
    /// which the did-not-shrink guard would discard.
    ///
    /// An empty result would erase the span the fold replaced — the defect
    /// ``SummarizationError/emptySummary`` exists for — so a cut that finds no
    /// text at all gives `summary` back unchanged and leaves the did-not-shrink
    /// guard to judge it. A `limit` of zero or below takes the same fallback:
    /// ``resolveOversizedSummary(_:within:summarizer:)`` reaches it when the
    /// pending-runs rendering alone spends the whole span byte budget, and the
    /// answer is the guard's judgment, never an emptied summary.
    ///
    /// - Parameters:
    ///   - summary: The summarizer's answer, unchanged.
    ///   - limit: The characters that answer may occupy.
    /// - Returns: `summary` when it already fits, and otherwise a prefix of it
    ///   that does.
    private static func cut(_ summary: String, toCharacters limit: Int) -> String {
        guard summary.utf8.count > limit else { return summary }

        if let sections = sectionAlignedPrefix(of: summary, withinBytes: limit) { return sections }

        let budgeted = UTF8Budget.prefix(of: summary, keepingAtMostBytes: limit)
        if let boundary = lastSentenceBoundary(in: budgeted) {
            let sentences = String(budgeted[...boundary])
            if !sentences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sentences }
        }
        if let space = budgeted.lastIndex(where: \.isWhitespace) {
            let words = String(budgeted[..<space])
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return words }
        }
        return budgeted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : budgeted
    }

    /// The last index of `text` holding a character a summary can end on: a
    /// line end, or a ``sentenceTerminators`` member that stands at the end of
    /// the text or before whitespace.
    ///
    /// The whitespace condition is what keeps the cut off a period inside a
    /// value — `.env.example`, `3.5`, `v1.2` — where a break would leave the
    /// value half-written. A line end counts on its own because a fold's
    /// summary is usually a list, and a list item ends at its line rather than
    /// at a full stop.
    ///
    /// - Parameter text: The text to search.
    /// - Returns: The index, or `nil` when the text holds no boundary.
    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        var boundary: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isNewline {
                boundary = index
            } else if sentenceTerminators.contains(character), next == text.endIndex || text[next].isWhitespace {
                boundary = index
            }
            index = next
        }
        return boundary
    }

    /// The longest prefix of `summary` that holds WHOLE numbered sections and
    /// fits inside `limit` bytes, or `nil` when no such prefix exists.
    ///
    /// This is the section-boundary step of ``cut(_:toCharacters:)``. A
    /// candidate cut point is the start of a section header other than the
    /// first one: everything before it is finished sections — the section a
    /// header opens ends exactly where the next header starts — plus whatever
    /// preamble the model wrote ahead of the scaffold. The prefix is measured
    /// and returned with its trailing whitespace dropped, and nothing else
    /// trimmed, so the stored summary stays a prefix of the model's answer up
    /// to that whitespace.
    ///
    /// A `summary` with fewer than two section headers carries no scaffold to
    /// respect, and a `limit` too small for even the first whole section
    /// leaves no candidate standing. Both answer `nil`, and
    /// ``cut(_:toCharacters:)`` falls back to the sentence boundary — its doc
    /// comment records that trade.
    ///
    /// The result is never empty: every candidate stands after the FIRST
    /// header, so its prefix holds that header's own line, whose `N. ` opening
    /// no whitespace trim can reach.
    ///
    /// - Parameters:
    ///   - summary: The summarizer's answer, unchanged.
    ///   - limit: The bytes the answer may occupy.
    /// - Returns: The whole-section prefix, or `nil` when none fits.
    private static func sectionAlignedPrefix(of summary: String, withinBytes limit: Int) -> String? {
        let headers = sectionHeaderStarts(in: summary)
        guard headers.count > 1 else { return nil }

        var best: String?
        for header in headers.dropFirst() {
            var end = header
            while end > summary.startIndex, summary[summary.index(before: end)].isWhitespace {
                end = summary.index(before: end)
            }
            let prefix = summary[..<end]
            guard prefix.utf8.count <= limit else { break }
            best = String(prefix)
        }
        return best
    }

    /// Every index of `text` at which a numbered-section header line starts, in
    /// order.
    ///
    /// A header is a line that opens, flush against the line start, with one
    /// or more ASCII digits, a period, and a space — the shape
    /// ``CompactionPrompt/default``'s scaffold instructs and the shape its
    /// summaries carry. An indented numbered line is a nested list item, not a
    /// section. A flush-left numbered list the model writes inside a section
    /// does match; a cut before such an item still lands between finished
    /// items, so the cost of the ambiguity is a cleanly shorter list.
    ///
    /// - Parameter text: The text to search.
    /// - Returns: The header start indexes, possibly empty.
    private static func sectionHeaderStarts(in text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            if lineOpensSection(text[lineStart..<lineEnd]) {
                starts.append(lineStart)
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return starts
    }

    /// Whether `line` opens a numbered section: one or more ASCII digits, then
    /// a period, then a space.
    ///
    /// - Parameter line: One line of a summary, without its line end.
    /// - Returns: `true` when the line is a section header.
    private static func lineOpensSection(_ line: Substring) -> Bool {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.endIndex < line.endIndex, line[digits.endIndex] == "." else {
            return false
        }
        let afterPeriod = line.index(after: digits.endIndex)
        return afterPeriod < line.endIndex && line[afterPeriod] == " "
    }

    /// `tokens` of ``Compactor/estimatedTokenCount(of:)``'s estimate, converted
    /// back into the characters that estimate divides.
    ///
    /// The inverse of ``estimatedTokens(of:)``, and the one place the
    /// conversion lives, so the bound the model is told and the size the
    /// did-not-shrink guard measures cannot drift apart.
    ///
    /// - Parameter tokens: A size in estimated tokens.
    /// - Returns: That size in characters.
    package static func characters(forEstimatedTokens tokens: Int) -> Int {
        Int(Double(tokens) * Compactor.charsPerTokenEstimate)
    }

    /// The ceiling, in tokens, one summarizer call generates under:
    /// `allowance` — what that call's own content earns, from
    /// ``summaryTokenAllowance(condensing:atRatio:)`` — plus
    /// ``reasoningTokenHeadroom``.
    ///
    /// The sum is what the call is given, because a reasoning model spends the
    /// same ceiling on its `<think>` block and on the answer after it. Passing
    /// the allowance alone leaves the answer no room at all — see
    /// ``reasoningTokenHeadroom`` for the measurement that states it.
    ///
    /// The sum is also why the ceiling cannot be the bound on the summary
    /// TEXT: it has to be wide enough for reasoning the answer never uses.
    /// The stated budget in ``summarizeOnce(_:prompt:summarizer:)`` is what
    /// aims the answer's size, and the fold's final summary is held to the
    /// span byte budget by ``resolveOversizedSummary(_:within:summarizer:)``.
    ///
    /// - Parameter allowance: The summary allowance the call's content earns.
    /// - Returns: The output ceiling for that call, in tokens.
    private func outputTokenCeiling(forSummaryAllowance allowance: Int) -> Int {
        allowance + reasoningTokenHeadroom
    }

    /// The part of that ceiling the summary text itself may occupy: the
    /// STATED budget's own size in estimated tokens, never below
    /// ``minimumSummaryTokens``.
    ///
    /// Sized from the budget the assembled prompt states, so the ceiling
    /// always covers the ask. The 1B re-baseline of 2026-08-20 (task
    /// ^xx02yn6) measured what a smaller allowance costs: the prompt asked
    /// for three quarters of the content while the allowance was still a
    /// quarter of it, the ceiling ended each answer mid-list before the facts
    /// stated late in the span, and 5 of 7 stored summaries lost their fact
    /// to that truncation rather than to the model.
    ///
    /// Never above ``maximumSummaryTokens``, because
    /// ``statedBudgetBytes(condensing:)`` is itself capped there.
    ///
    /// Measured on the content alone, never on the assembled prompt: the
    /// compaction instructions are the same however small the span is, and
    /// charging a summary for the length of the instructions asking for it
    /// would let a short span buy a long summary.
    ///
    /// - Parameter content: The content the call will condense — a rendered
    ///   chunk of turns, or a batch of prior summaries.
    /// - Returns: The allowance the stated budget needs, in tokens.
    private func summaryTokenAllowance(condensing content: String) -> Int {
        max(
            Self.minimumSummaryTokens,
            Int((Double(statedBudgetBytes(condensing: content)) / Compactor.charsPerTokenEstimate).rounded(.up)))
    }

    /// The bytes the STATED budget names for a call condensing `content`:
    /// ``statedBudgetShareOfContent`` of the content's own UTF-8 size, capped
    /// at what ``maximumSummaryTokens`` occupies in characters so the final
    /// summary of a conversation of any length stays bounded however much one
    /// call ingests.
    ///
    /// - Parameter content: The content the call will condense.
    /// - Returns: The stated budget, in UTF-8 bytes.
    private func statedBudgetBytes(condensing content: String) -> Int {
        min(
            Int(Double(content.utf8.count) * Self.statedBudgetShareOfContent),
            Self.characters(forEstimatedTokens: maximumSummaryTokens))
    }

    /// The allowance no single summarizer call's summary text may exceed,
    /// however much content that call was handed: what a full
    /// ``maxChunkTokens`` of content earns under ``summaryTokenRatio``.
    ///
    /// Chunking already keeps most calls at or under ``maxChunkTokens``, so for
    /// them this cap never binds. It is applied to every call all the same —
    /// ``summaryTokenAllowance(condensing:atRatio:)`` clamps to it, and every call
    /// reaches that through ``summarizeOnce(_:prompt:summarizer:)`` — rather
    /// than to a listed set of calls, because a call can be handed more than
    /// ``maxChunkTokens`` in more than one way (see ``maxChunkTokens``).
    /// Clamping unconditionally is what keeps the final summary of a long
    /// conversation bounded, the defect ``summaryTokenRatio`` exists to close,
    /// without the bound depending on any such list being complete.
    private var maximumSummaryTokens: Int {
        summaryTokenAllowance(ingesting: maxChunkTokens)
    }

    /// ``summaryTokenRatio`` of `tokens`, rounded UP and floored at
    /// ``minimumSummaryTokens`` — the one place the allowance arithmetic
    /// lives, shared by the per-call allowance and the cap it is clamped to.
    ///
    /// The rounding up is why the cap is reached one token of content earlier
    /// than a division suggests: a ratio of `0.25` reaches a cap of `500` as
    /// soon as `0.25 * tokens` passes `499`.
    ///
    /// - Parameter tokens: The estimated size, in tokens, of what a call
    ///   ingests.
    /// - Returns: The allowance those tokens earn, in tokens.
    private func summaryTokenAllowance(ingesting tokens: Int) -> Int {
        max(Self.minimumSummaryTokens, Int((Double(tokens) * summaryTokenRatio).rounded(.up)))
    }

    // MARK: - Chunking

    /// Splits `turns` into groups whose estimated token size each stays at or
    /// under `maxTokens`, never splitting a turn between two groups — a
    /// single oversized turn becomes its own (over-`maxTokens`) group rather
    /// than being split, the same "never split a turn" invariant every other
    /// compaction stage honors.
    ///
    /// - Parameters:
    ///   - turns: The turns to chunk, in order.
    ///   - maxTokens: The estimated-token ceiling per chunk.
    /// - Returns: `turns` grouped into ordered chunks, each (except a lone
    ///   oversized turn) at or under `maxTokens`.
    static func chunk(_ turns: [TranscriptTurn], maxTokens: Int) -> [[TranscriptTurn]] {
        binPack(turns, maxTokens: maxTokens) { turn in
            Compactor.estimatedTokenCount(of: Transcript(entries: turn.entries))
        }
    }

    /// Splits `summaries` into groups whose joined estimated token size each
    /// stays at or under `maxTokens`, never splitting a single summary
    /// between two groups — ``reduce(_:prompt:summarizer:)``'s own
    /// re-chunking step, applied to plain strings rather than
    /// ``TranscriptTurn``s.
    ///
    /// - Parameters:
    ///   - summaries: The summaries to group, in order.
    ///   - maxTokens: The estimated-token ceiling per group.
    /// - Returns: `summaries` grouped into ordered batches, each (except a
    ///   lone oversized summary) at or under `maxTokens`.
    static func chunkStrings(_ summaries: [String], maxTokens: Int) -> [[String]] {
        binPack(summaries, maxTokens: maxTokens) { estimatedTokens(of: $0) }
    }

    /// The shared greedy bin-packing loop behind both ``chunk(_:maxTokens:)``
    /// and ``chunkStrings(_:maxTokens:)``: accumulates `items` into a running
    /// group until the next item would push it over `maxTokens`, then starts
    /// a new group — never splitting a single item, so a lone
    /// already-oversized item becomes its own (over-`maxTokens`) group.
    ///
    /// - Parameters:
    ///   - items: The items to pack, in order.
    ///   - maxTokens: The estimated-token ceiling per group.
    ///   - tokens: Each item's own estimated token size.
    /// - Returns: `items` grouped into ordered batches, each (except a lone
    ///   oversized item) at or under `maxTokens`.
    private static func binPack<Item>(
        _ items: [Item],
        maxTokens: Int,
        tokens: (Item) -> Int
    ) -> [[Item]] {
        var chunks: [[Item]] = []
        var current: [Item] = []
        var currentTokens = 0

        for item in items {
            let itemTokens = tokens(item)
            if !current.isEmpty && currentTokens + itemTokens > maxTokens {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(item)
            currentTokens += itemTokens
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Estimates `text`'s size in tokens via the same character-ratio
    /// estimate ``Compactor/estimatedTokenCount(of:)`` uses for a transcript
    /// (``Compactor/charsPerTokenEstimate``), applied directly to a plain
    /// string's UTF-8 byte count rather than a JSON-encoded payload — used by
    /// ``reduce(_:prompt:summarizer:)`` to size chunk summaries, which are
    /// plain text, not transcript entries.
    ///
    /// `package` rather than `internal` because the compaction evals report a
    /// discarded summary in the SAME estimate the stage sized it by, and they
    /// report it from `FoundationModelsRouterEvalSupport`, a plain package
    /// target that cannot reach `internal` through `@testable`.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count.
    package static func estimatedTokens(of text: String) -> Int {
        Int((Double(text.utf8.count) / Compactor.charsPerTokenEstimate).rounded(.up))
    }

    // MARK: - Rendering

    /// Renders `turns`' entries to plain text for the summarizer to read: one
    /// line per prompt/response/tool-call/tool-output/reasoning entry,
    /// labeled by role, in original order.
    ///
    /// `.instructions` never appears here (it is always the header, excluded
    /// from the old span before this is called).
    ///
    /// - Parameter turns: The turns to render, in order.
    /// - Returns: The rendered text.
    private static func render(_ turns: [TranscriptTurn]) -> String {
        turns.flatMap(\.entries).compactMap(renderLine).joined(separator: "\n")
    }

    /// Renders a single entry to one labeled line (or, for `.toolCalls`, one
    /// line per call), or `nil` for an entry kind that carries nothing to
    /// summarize.
    ///
    /// - Parameter entry: The entry to render.
    /// - Returns: The rendered line(s), or `nil`.
    private static func renderLine(_ entry: Transcript.Entry) -> String? {
        switch entry {
        case .prompt(let prompt):
            return "User: \(text(of: prompt.segments))"
        case .response(let response):
            return "Assistant: \(text(of: response.segments))"
        case .toolCalls(let calls):
            return calls.map { "Tool call: \($0.toolName)(\($0.arguments.jsonString))" }.joined(separator: "\n")
        case .toolOutput(let output):
            return "Tool output (\(output.toolName)): \(text(of: output.segments))"
        case .reasoning(let reasoning):
            return "Reasoning: \(text(of: reasoning.segments))"
        case .instructions:
            return nil
        @unknown default:
            return nil
        }
    }

    /// The joined content of every `.text` segment in `segments`, in order —
    /// the rendering counterpart of ``TranscriptEntryMapper``'s own
    /// `flattenedText(_:)`, kept in this module since it operates on live
    /// `Transcript.Segment` values rather than persisted `SegmentPayload`s.
    ///
    /// `internal` rather than `private`, and load-bearing at that width: the
    /// compaction eval dataset (`Tests/FoundationModelsRouterEvals`) reads its
    /// seed transcripts through this same function via `@testable import`, so
    /// what the dataset measures is the text a fold really shows the model.
    /// Narrowing it again would put a second copy of this flattening back in
    /// the test target, which is the duplication that width removes.
    ///
    /// - Parameter segments: The segments to flatten.
    /// - Returns: The joined text content.
    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined(separator: "\n")
    }
}
