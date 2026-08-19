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

    /// The fraction of the content a single summarizer call condenses that its
    /// own summary text may occupy — the compression a fold is run for, and one
    /// of the two amounts that make the ceiling every call generates under
    /// (``CompactionSummarizer/summarize(_:maxTokens:)``'s `maxTokens`; the
    /// other is ``reasoningTokenHeadroom``).
    ///
    /// Defaults to `0.25`. The number this replaces was no number at all: the
    /// call went out unbounded and resolved to the generation path's generic
    /// per-turn default, which on real hardware produced a 3346-character
    /// summary for a span estimated at 1068 tokens — four fifths of what it
    /// replaced, for a fold that then saved almost nothing. A quarter is the
    /// compression a summary of a conversation is worth writing.
    ///
    /// The ceiling is per call, sized against that call's own content, so it
    /// holds at every level of the map-reduce tree rather than only over the
    /// whole span: a chunk's summary is sized against that chunk, and each
    /// reduce round's summary against the summaries it joins.
    ///
    /// A share of the input alone would still leave the final summary of an
    /// arbitrarily long span unbounded, because a call can be handed more than
    /// ``maxChunkTokens`` (see that property — neither packer splits a single
    /// item), and a quarter of *that* grows with the span.
    /// ``maximumSummaryTokens`` closes it without having to know which calls
    /// those are: it caps every call's summary allowance at what a full
    /// ``maxChunkTokens`` of content earns, so the bound holds for every call
    /// a fold makes, and therefore for the final summary of a span of any
    /// length.
    public var summaryTokenRatio: Double

    /// The tokens, in addition to the summary allowance, every summarizer call
    /// is given for the reasoning a model writes before its answer.
    ///
    /// Defaults to `4096`. The two amounts are added rather than shared,
    /// because they scale with different things. The summary allowance scales
    /// with the content, which is what ``summaryTokenRatio`` states. The
    /// reasoning does not: how much a model thinks before it answers is a
    /// property of the model, not of the span, so taking a fraction of a small
    /// span would leave a reasoning model no room at all while a large span
    /// would hand it more than it can use. A fixed amount beside the fraction
    /// says exactly that.
    ///
    /// Measurement gives the default, and it is this repository's own:
    /// `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift`
    /// records that the gated model always writes a `<think>` block first, that
    /// a ceiling of `512` leaves the response empty, and that `4096` does not.
    /// Before this amount existed, the largest ceiling a summarizer call could
    /// ask for was `500` — under the value already known to fail — and every
    /// gated fold stored an empty summary as a result.
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

    /// The largest share of a call's own content its summary text may KEEP —
    /// the bound ``cut(_:toCharacters:)`` applies, and deliberately not
    /// ``summaryTokenRatio``.
    ///
    /// The two ratios have two different jobs, and `^azd033m` measured what it
    /// costs to make one number do both.
    ///
    /// ``summaryTokenRatio`` is the COMPRESSION a fold is run for. It sizes
    /// what the call is given room to generate
    /// (``outputTokenCeiling(forSummaryAllowance:)``) and it sizes
    /// ``maximumSummaryTokens``, the cap that keeps the final summary of a
    /// conversation of any length bounded. Both of those stay as they were.
    ///
    /// This ratio is the SAFETY bound, and all it has to guarantee is what
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``'s
    /// did-not-shrink guard requires: a summary smaller than the span it
    /// replaces, so the fold is applied rather than discarded. Nothing more.
    /// Every byte a cut removes past that point is content the model chose to
    /// write and the fold then threw away, chosen by position rather than by
    /// meaning, because a prefix cut keeps what was said first.
    ///
    /// Cutting to the compression target instead measured exactly that loss.
    /// One fold of `Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift`'s
    /// fixture against a real 1B model answered 330 estimated tokens over a
    /// 643-token span — already comfortably inside what the guard needs — and
    /// the cut stored 160 of them. The answer named a fact stated at the end of
    /// the span twice; the stored summary named it not at all.
    ///
    /// `0.8` states the guarantee with a margin. The margin has to cover the
    /// TWO places the two sides disagree, and they sit on opposite sides of
    /// the comparison: the first changes what this bound is measured against,
    /// the second changes what the guard measures.
    ///
    /// The first is the rendering. This bound is measured against the RENDERED
    /// content of the call, which carries a `User: `/`Assistant: ` label per
    /// entry and a line break between them, while the guard measures the
    /// span's entries. On the fixture above rendering came to 1.01x the span,
    /// and a fifth covers that many times over.
    ///
    /// **That 1.01x is a property of that one fixture, not of this ratio.** The
    /// labels and the separator cost about 19 bytes per prompt/response turn
    /// however short the turn is. So a span of many very short turns — entries
    /// averaging under roughly 40 bytes of text, a line of a few words each —
    /// renders past 1.25x the span, and past 1.25x this ratio of the rendered
    /// content EXCEEDS the span it replaces. This bound then guarantees
    /// nothing on its own, and
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``'s
    /// did-not-shrink guard is the only thing left standing. That guard is why
    /// a fixture-measured margin is safe to ship: the worst this bound can do
    /// is let a fold be discarded, which is the state that preceded it.
    ///
    /// The second is the pending runs, and it sits on the guard's side of the
    /// comparison: ``cut(_:toCharacters:)`` bounds the summary TEXT, while the
    /// guard measures the whole replacement ENTRY.
    /// ``CompactionSegment/boundaryEntry(id:summaryText:content:)`` appends a
    /// second `.text` segment carrying
    /// ``CompactionSegment/renderedPendingRuns(_:)`` whenever the session has
    /// parked runs, and ``SegmentPayload/contentByteCount`` counts a `.text`
    /// segment in full, so the guard weighs those bytes against the span and
    /// this bound never saw them. Measured: 134 bytes of heading — never on
    /// their own, because that segment exists only when there is at least one
    /// run — plus, per run, 20 bytes of framing, the run's
    /// ``ULID/stringLength``-character completion token, its op, and either 29
    /// bytes for the no-progress clause or 22 bytes plus the progress detail.
    /// One parked run with an eight-byte op and no progress reported renders
    /// 217 bytes, and each further such run adds 84.
    ///
    /// **That cost is charged per parked run, so unlike the labels it does not
    /// shrink against a larger span.** Six such runs come to 637 bytes — more
    /// than the whole 512-byte bound the ``minimumSummaryTokens`` floor
    /// produces, and 32% of the 2000-byte bound the ``maximumSummaryTokens``
    /// cap produces — so a small span with several parked runs can spend the
    /// margin on that rendering alone, and the fold is discarded whatever the
    /// summary says. `^64f3hnv` carries that behaviour; this ratio is not the
    /// place to fix it.
    ///
    /// The rest of the margin is a floor on what a fold saves: a fold that
    /// could not save a fifth of the span it replaced was not worth the
    /// generation it cost.
    ///
    /// Raising this ratio does not widen the final summary of a long
    /// conversation, because ``maximumSummaryTokens`` clamps this bound too and
    /// is computed from ``summaryTokenRatio`` alone. A call handed a full
    /// ``maxChunkTokens`` is cut to exactly what it was cut to before.
    ///
    /// The band that DID change is far wider than that, and naming it "the
    /// calls where the cap does not bind" was wrong: the cap binding on THIS
    /// ratio does not mean it bound on the old one. At the defaults —
    /// ``maxChunkTokens`` `2000` and ``summaryTokenRatio`` `0.25`, so
    /// ``maximumSummaryTokens`` `500` — this bound reaches the cap at content
    /// of 624 estimated tokens, while the old bound reached it only at 1997.
    /// So every call from 161 estimated tokens (under that both bounds sit on
    /// ``minimumSummaryTokens``) up to 1996 keeps strictly more than it did,
    /// and a call in the middle of that band keeps several times more: at 650
    /// estimated tokens the old bound was 163 tokens and this one is 500.
    /// The fixture this defect was measured on sits inside that band, and it
    /// shows why the cap is the wrong thing to reason from — at about 650
    /// estimated tokens of rendered content the cap DOES bind on retention
    /// (`0.8 * 650` is 520, clamped to 500), and the stored summary still went
    /// from 160 tokens to 330.
    public static let summaryRetentionRatio = 0.8

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
    ///     Defaults to `4096`.
    public init(
        keepRecentTurns: Int = 4,
        maxChunkTokens: Int = 2000,
        summaryTokenRatio: Double = 0.25,
        reasoningTokenHeadroom: Int = 4096
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
    ///   - pendingRuns: The run-plane summaries of the runs still parked in
    ///     the session's `SessionMailbox` at the moment this boundary is
    ///     written, in park order. When non-empty they land in the resulting
    ///     ``CompactionSegment/Content/pendingRuns`` and as an additional
    ///     model-visible text segment on the summary entry
    ///     (``CompactionSegment/renderedPendingRuns(_:)``); when empty —
    ///     the default, and always the case for the bare-session recipe,
    ///     which has no mailbox — the boundary is exactly as before.
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

        let summaryText = try await summarize(old, prompt: prompt, summarizer: summarizer)

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

        return Folded(transcript: finalTranscript, summary: summaryText, summaryEntryId: entryId)
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
    /// Every call made through here is bounded twice over, because the two
    /// bounds reach different things.
    ///
    /// ``outputTokenCeiling(forSummaryAllowance:)`` bounds what the model may
    /// GENERATE, and its summary allowance is never larger than
    /// ``maximumSummaryTokens`` however much content the call was handed. But
    /// that ceiling covers the reasoning and the answer together (see
    /// ``reasoningTokenHeadroom``), so it never bounds the ANSWER: a decoder
    /// has one stop, and it is already spoken for by the `<think>` block.
    /// ``cut(_:toCharacters:)`` is what bounds the answer, and it does it to
    /// the text the call came back with rather than to the generation.
    ///
    /// The gated run of 2026-08-17 measured why the second bound is needed.
    /// Every one of 7 seeds was called at a ceiling of 4224 tokens against a
    /// summary allowance of 128, and every one answered with 374 to 698 real
    /// tokens of summary — 1.30x to 2.07x the estimated size of the span it was
    /// condensing, so
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// discarded all 7 folds.
    ///
    /// The assembled prompt states no length of its own. `^azd033m` measured
    /// what stating one cost against that same model, and
    /// ``cut(_:toCharacters:)`` records the two numbers.
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
    /// - Returns: The summarizer's answer, cut down to the share of this
    ///   call's own content it may retain — see ``cut(_:toCharacters:)``.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws,
    ///   unmodified, or ``SummarizationError/emptySummary`` when that answer
    ///   holds no characters. The refusal reads the answer as the model wrote
    ///   it, before the cut, so a fold that produced nothing is reported as
    ///   such rather than cut to nothing.
    private func summarizeOnce(
        _ content: String,
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        let allowance = summaryTokenAllowance(condensing: content, atRatio: summaryTokenRatio)
        let retained = summaryTokenAllowance(condensing: content, atRatio: Self.summaryRetentionRatio)
        let summary = try await summarizer.summarize(
            "\(prompt.text)\n\n---\n\n\(content)",
            maxTokens: outputTokenCeiling(forSummaryAllowance: allowance)
        )
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.emptySummary
        }
        return Self.cut(summary, toCharacters: Self.characters(forEstimatedTokens: retained))
    }

    /// The characters that end a sentence, and so mark a place a summary can be
    /// cut without ending it mid-thought.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// `summary`, cut down to at most `limit` characters at the last sentence
    /// or list-item boundary that fits inside them.
    ///
    /// This is the bound on the summary TEXT, and it is applied in code rather
    /// than asked of the model, for two measured reasons.
    ///
    /// Asking does not work, and it costs. Commit `c26fbbe` stated the bound in
    /// the assembled prompt — "write at most N characters ... a summary that is
    /// not clearly shorter than what it replaces saves nothing and is thrown
    /// away. Compress hard" — and `^azd033m` measured one fold of that prompt
    /// against `Muse-Glimmer-30B-4bit` at a ceiling of 4249 tokens. Without the
    /// directive the model answered with 839 estimated tokens in 205.3 s; with
    /// it the model spent the whole ceiling inside its `<think>` block and
    /// answered with nothing at all, in 283.6 s. A length stated as a
    /// requirement reads as an optimisation problem, and a reasoning model
    /// optimises until the hard stop.
    ///
    /// Not asking does not work either, on its own. The same control run — the
    /// prompt with no directive, which is what shipped before `c26fbbe` — wrote
    /// 839 estimated tokens against the 600-token span it was replacing, so
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// discarded the fold, exactly as it discarded 7 of 7 gated seeds in
    /// `^fm5ddk9`.
    ///
    /// A cut in code answers both. It needs nothing from the model, it holds
    /// whatever the model writes, and it makes "a fold's summary is smaller
    /// than the span it replaces" a property of this file rather than a hope
    /// about a generation.
    ///
    /// It is a SAFETY bound and not the compression device, and `limit` says
    /// so: it is ``summaryRetentionRatio`` of the call's content, not
    /// ``summaryTokenRatio`` of it. The reason is that this cut keeps a PREFIX,
    /// so it is content-blind — it keeps what the model said first and drops
    /// what it said last, and the last thing a span states is usually the last
    /// thing its summary states. Every byte cut past what the did-not-shrink
    /// guard requires is a fact discarded by position rather than by meaning,
    /// and a fold that shrank the transcript and dropped the fact it existed to
    /// carry has not worked. So the bound sits as close to that requirement as
    /// it safely can, and the compression a fold is run for is left to the
    /// prompt and to the generation ceiling.
    ///
    /// `limit` is in the unit
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// really measures — UTF-8 content bytes over
    /// ``Compactor/charsPerTokenEstimate``, from
    /// ``characters(forEstimatedTokens:)`` — so the size cut to here and the
    /// size the did-not-shrink guard reads are the same number. (Bytes and
    /// characters part company on non-ASCII text, and the byte count is the one
    /// that binds, which cuts a little shorter rather than a little longer.)
    ///
    /// The cut falls on a boundary rather than on the byte the budget runs out
    /// on, because a summary is what a resumed session READS. Three fallbacks,
    /// in order, and the last one is what keeps the result non-empty:
    ///
    /// 1. The last sentence terminator or line end inside the budget.
    /// 2. Failing that, the last word boundary inside it.
    /// 3. Failing that, the budget itself.
    ///
    /// An empty result would erase the span the fold replaced — the defect
    /// ``SummarizationError/emptySummary`` exists for — so a cut that finds no
    /// text at all gives `summary` back unchanged and leaves the did-not-shrink
    /// guard to judge it.
    ///
    /// - Parameters:
    ///   - summary: The summarizer's answer, unchanged.
    ///   - limit: The characters that answer may occupy.
    /// - Returns: `summary` when it already fits, and otherwise a prefix of it
    ///   that does.
    private static func cut(_ summary: String, toCharacters limit: Int) -> String {
        guard summary.utf8.count > limit else { return summary }

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

    /// `tokens` of ``Compactor/estimatedTokenCount(of:)``'s estimate, converted
    /// back into the characters that estimate divides.
    ///
    /// The inverse of ``estimatedTokens(of:)``, and the one place the
    /// conversion lives, so the bound the model is told and the size the
    /// did-not-shrink guard measures cannot drift apart.
    ///
    /// - Parameter tokens: A size in estimated tokens.
    /// - Returns: That size in characters.
    private static func characters(forEstimatedTokens tokens: Int) -> Int {
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
    /// ``cut(_:toCharacters:)`` is what bounds the answer, at
    /// ``summaryRetentionRatio`` of the same content rather than at this
    /// allowance — see that constant for why the two numbers differ.
    ///
    /// - Parameter allowance: The summary allowance the call's content earns.
    /// - Returns: The output ceiling for that call, in tokens.
    private func outputTokenCeiling(forSummaryAllowance allowance: Int) -> Int {
        allowance + reasoningTokenHeadroom
    }

    /// The part of that ceiling the summary text itself may occupy:
    /// ``summaryTokenRatio`` of `content`'s own estimated size, never below
    /// ``minimumSummaryTokens`` and never above ``maximumSummaryTokens``.
    ///
    /// Measured on the content alone, never on the assembled prompt: the
    /// compaction instructions are the same however small the span is, and
    /// charging a summary for the length of the instructions asking for it
    /// would let a short span buy a long summary.
    ///
    /// - Parameters:
    ///   - content: The content the call will condense — a rendered chunk of
    ///     turns, or a batch of prior summaries.
    ///   - ratio: The share of `content` to take, either ``summaryTokenRatio``
    ///     for the generation ceiling or ``summaryRetentionRatio`` for the cut.
    ///     Stated by the caller rather than fixed here, because one arithmetic
    ///     serves both bounds and the two differ only in this number.
    /// - Returns: That share of the call's content, in tokens.
    private func summaryTokenAllowance(condensing content: String, atRatio ratio: Double) -> Int {
        min(maximumSummaryTokens, summaryTokenAllowance(ingesting: Self.estimatedTokens(of: content), atRatio: ratio))
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
    /// It is computed from ``summaryTokenRatio`` alone, never from
    /// ``summaryRetentionRatio``, and both bounds clamp to it. That is what
    /// held the final summary of a long conversation where it already was when
    /// the retention ratio went up: a call handed a full ``maxChunkTokens``
    /// reaches this cap under either ratio.
    ///
    /// It does NOT make that change a small-fold one, and reading it that way
    /// is the mistake ``summaryRetentionRatio`` records. Reaching this cap
    /// under the retention ratio is not the same as reaching it under
    /// ``summaryTokenRatio``: at the defaults the first happens at content of
    /// 624 estimated tokens and the second only at 1997, so every call between
    /// the two keeps more than it did before.
    private var maximumSummaryTokens: Int {
        summaryTokenAllowance(ingesting: maxChunkTokens, atRatio: summaryTokenRatio)
    }

    /// `ratio` of `tokens`, rounded UP and floored at ``minimumSummaryTokens``
    /// — the one place the allowance arithmetic lives, shared by the per-call
    /// allowance and the cap it is clamped to.
    ///
    /// The rounding up is why a bound reaches a cap one token of content
    /// earlier than a division suggests. A `ratio` of `0.8` reaches a cap of
    /// `500` as soon as `0.8 * tokens` passes `499`, which is at 624 tokens
    /// and not at 625.
    ///
    /// - Parameters:
    ///   - tokens: The estimated size, in tokens, of what a call ingests.
    ///   - ratio: The share of `tokens` to take.
    /// - Returns: That share of it, in tokens.
    private func summaryTokenAllowance(ingesting tokens: Int, atRatio ratio: Double) -> Int {
        max(Self.minimumSummaryTokens, Int((Double(tokens) * ratio).rounded(.up)))
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
