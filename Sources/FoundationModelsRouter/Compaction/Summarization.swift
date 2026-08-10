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
    /// - Parameters:
    ///   - prompt: The assembled compaction instructions plus content to
    ///     condense.
    ///   - maxTokens: The ceiling, in tokens, on this call's own answer — see
    ///     ``Summarization/summaryTokenRatio`` for how a fold sizes it.
    /// - Returns: The model's complete text response.
    /// - Throws: If summarization fails.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String
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
public struct Summarization: Sendable {
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
    /// ``maximumOutputTokens`` caps what any one call may answer, however much
    /// it was handed.
    public var maxChunkTokens: Int

    /// The fraction of the content a single summarizer call condenses that
    /// its own answer may occupy — the compression a fold is run for, turned
    /// into the ceiling every call generates under
    /// (``CompactionSummarizer/summarize(_:maxTokens:)``'s `maxTokens`).
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
    /// ``maximumOutputTokens`` closes it without having to know which calls
    /// those are: it caps every call's ceiling at what a full
    /// ``maxChunkTokens`` of content earns, so the bound holds for every call
    /// a fold makes, and therefore for the final summary of a span of any
    /// length.
    public var summaryTokenRatio: Double

    /// The floor, in tokens, no call's ceiling is squeezed below — `128`,
    /// roughly a few dense sentences.
    ///
    /// ``summaryTokenRatio`` alone would hand a small span a ceiling too tight
    /// to say anything in, and a generation cut off mid-sentence is worse than
    /// a slightly larger one: the ceiling is a hard stop, not a target the
    /// model aims at. A fold that still fails to shrink the transcript is
    /// caught where it should be —
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` returns
    /// the original transcript rather than apply it.
    public static let minimumSummaryTokens = 128

    /// Creates a summarization stage.
    ///
    /// - Parameters:
    ///   - keepRecentTurns: How many of the newest turns to leave untouched.
    ///     Defaults to `4`.
    ///   - maxChunkTokens: The estimated-token ceiling per summarizer call
    ///     before chunking kicks in. Defaults to `2000`.
    ///   - summaryTokenRatio: The fraction of the content it condenses a
    ///     single summarizer call's answer may occupy. Defaults to `0.25`.
    public init(keepRecentTurns: Int = 4, maxChunkTokens: Int = 2000, summaryTokenRatio: Double = 0.25) {
        self.keepRecentTurns = keepRecentTurns
        self.maxChunkTokens = maxChunkTokens
        self.summaryTokenRatio = summaryTokenRatio
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
    ///   degraded result.
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
        let textSegmentId = "\(entryId)-text"
        let pendingRunsSegmentId = "\(entryId)-pending-runs"
        let foldedEntryIds = old.flatMap(\.entries).map(\.id)
        let recentEntries = recent.flatMap(\.entries)
        let stagesApplied = priorStagesApplied + [Self.stageName]
        let liveWindowEntryIds = header.map(\.id) + [entryId] + recentEntries.map(\.id)

        func makeSummaryEntry(tokensAfter: Int) -> Transcript.Entry {
            let content = CompactionSegment.Content(
                liveWindowEntryIds: liveWindowEntryIds,
                foldedEntryIds: foldedEntryIds,
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                stagesApplied: stagesApplied,
                promptName: prompt.name,
                pendingRuns: pendingRuns.isEmpty ? nil : pendingRuns
            )
            var segments: [Transcript.Segment] = [
                .text(Transcript.TextSegment(id: textSegmentId, content: summaryText))
            ]
            // A session with no parked runs adds nothing; one with parked
            // runs carries their rendering as a second text segment — the
            // only segment kind the model-facing transcript rendering reads —
            // so a post-compaction model knows its tokens and can call
            // status() (see ``CompactionSegment/renderedPendingRuns(_:)``).
            if !pendingRuns.isEmpty {
                segments.append(
                    .text(
                        Transcript.TextSegment(
                            id: pendingRunsSegmentId,
                            content: CompactionSegment.renderedPendingRuns(pendingRuns)
                        )
                    )
                )
            }
            segments.append(.custom(CompactionSegment(content: content)))
            return .response(
                Transcript.Response(
                    id: entryId,
                    assetIDs: [],
                    segments: segments
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

        return Folded(transcript: finalTranscript, summary: summaryText)
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
    /// ``summarizeOnce(_:prompt:summarizer:)``, whose ceiling is clamped to
    /// ``maximumOutputTokens``, so no round's answer grows with the span
    /// however much that round ingests.
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
            // left. Over budget on its *input* only: this call's answer is
            // still capped at `maximumOutputTokens`, so a span shaped this way
            // cannot buy a final summary that grows with it.
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
    /// Every call made through here is bounded by ``outputTokenCeiling(condensing:)``,
    /// so a summary can never come back the size of what it condenses — the
    /// defect ``summaryTokenRatio`` records — and never larger than
    /// ``maximumOutputTokens``, however much content the call was handed.
    private func summarizeOnce(
        _ content: String,
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        try await summarizer.summarize(
            "\(prompt.text)\n\n---\n\n\(content)",
            maxTokens: outputTokenCeiling(condensing: content)
        )
    }

    /// The ceiling, in tokens, a single summarizer call condensing `content`
    /// may answer within: ``summaryTokenRatio`` of `content`'s own estimated
    /// size, never below ``minimumSummaryTokens`` and never above
    /// ``maximumOutputTokens``.
    ///
    /// Measured on the content alone, never on the assembled prompt: the
    /// compaction instructions are the same however small the span is, and
    /// charging a summary for the length of the instructions asking for it
    /// would let a short span buy a long summary.
    ///
    /// - Parameter content: The content the call will condense — a rendered
    ///   chunk of turns, or a batch of prior summaries.
    /// - Returns: The output ceiling for that call, in tokens.
    private func outputTokenCeiling(condensing content: String) -> Int {
        min(maximumOutputTokens, outputTokenCeiling(ingesting: Self.estimatedTokens(of: content)))
    }

    /// The ceiling no single summarizer call's answer may exceed, however much
    /// content that call was handed: what a full ``maxChunkTokens`` of content
    /// earns under ``summaryTokenRatio``.
    ///
    /// Chunking already keeps most calls at or under ``maxChunkTokens``, so for
    /// them this cap never binds. It is applied to every call all the same —
    /// ``outputTokenCeiling(condensing:)`` clamps to it, and every call reaches
    /// that through ``summarizeOnce(_:prompt:summarizer:)`` — rather than to a
    /// listed set of calls, because a call can be handed more than
    /// ``maxChunkTokens`` in more than one way (see ``maxChunkTokens``).
    /// Clamping unconditionally is what keeps the final summary of a long
    /// conversation bounded, the defect ``summaryTokenRatio`` exists to close,
    /// without the bound depending on any such list being complete.
    private var maximumOutputTokens: Int {
        outputTokenCeiling(ingesting: maxChunkTokens)
    }

    /// ``summaryTokenRatio`` of `tokens`, floored at ``minimumSummaryTokens`` —
    /// the one place the ceiling arithmetic lives, shared by the per-call
    /// ceiling and the cap it is clamped to.
    ///
    /// - Parameter tokens: The estimated size, in tokens, of what a call
    ///   ingests.
    /// - Returns: The share of it that call's answer may occupy, in tokens.
    private func outputTokenCeiling(ingesting tokens: Int) -> Int {
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
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count.
    static func estimatedTokens(of text: String) -> Int {
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
    /// `flattenedText(_:)`, kept local since it operates on live
    /// `Transcript.Segment` values rather than persisted `SegmentPayload`s.
    ///
    /// - Parameter segments: The segments to flatten.
    /// - Returns: The joined text content.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined(separator: "\n")
    }
}
