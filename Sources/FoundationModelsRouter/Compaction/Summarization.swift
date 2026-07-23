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
    /// being condensed (see ``Summarization/apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:)``).
    ///
    /// - Parameter prompt: The assembled compaction instructions plus content
    ///   to condense.
    /// - Returns: The model's complete text response.
    /// - Throws: If summarization fails.
    func summarize(_ prompt: String) async throws -> String
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
/// ``Compactor/compact(_:prompt:budget:summarizer:)`` invokes it directly as
/// the pipeline's last resort, once the deterministic stages alone don't land
/// the transcript under target.
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
    /// Defaults to `4` (compaction_plan.md §1.3), matching
    /// ``ToolOutputElision``/``TurnTruncation``'s own default so every stage
    /// agrees on where the recency window starts.
    public var keepRecentTurns: Int

    /// The estimated-token ceiling (``Compactor/estimatedTokenCount(of:)``'s
    /// character-ratio estimate) a single summarizer call's rendered content
    /// may reach before the folded span is split into multiple chunks,
    /// summarized independently (map), and their summaries re-summarized
    /// (reduce) into one final summary — so no summarizer call ever has to
    /// ingest more than this, however long the folded span is. The reduce
    /// step itself re-chunks and re-reduces when the chunk summaries
    /// themselves would exceed this in one call (see
    /// ``reduce(_:prompt:summarizer:)``), so the ceiling holds at every level
    /// of the map-reduce tree, not just the first.
    public var maxChunkTokens: Int

    /// Creates a summarization stage.
    ///
    /// - Parameters:
    ///   - keepRecentTurns: How many of the newest turns to leave untouched.
    ///     Defaults to `4`.
    ///   - maxChunkTokens: The estimated-token ceiling per summarizer call
    ///     before chunking kicks in. Defaults to `2000`.
    public init(keepRecentTurns: Int = 4, maxChunkTokens: Int = 2000) {
        self.keepRecentTurns = keepRecentTurns
        self.maxChunkTokens = maxChunkTokens
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
    ///     transcript given to ``Compactor/compact(_:prompt:budget:summarizer:)``,
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
    ///     ``Compactor/compact(_:prompt:budget:summarizer:)`` already
    ///     attempted before falling back to this stage (e.g.
    ///     `["ToolOutputElision", "TurnTruncation"]`) — this stage's own
    ///     ``stageName`` is appended to produce the resulting
    ///     ``CompactionSegment/Content/stagesApplied``.
    ///   - summarizer: The model called to condense text.
    /// - Returns: The folded transcript and summary text, or `nil` when there
    ///   is no old span to fold (every turn is inside the recency window) —
    ///   the same "oversized tail" case the deterministic stages report as a
    ///   shortfall, since summarizing nothing cannot help either.
    /// - Throws: Whatever `summarizer.summarize(_:)` throws, unmodified — a
    ///   summarizer failure is a real error, never silently swallowed into a
    ///   degraded result.
    public func apply(
        _ transcript: Transcript,
        prompt: CompactionPrompt,
        tokensBefore: Int,
        priorStagesApplied: [String],
        summarizer: any CompactionSummarizer
    ) async throws -> Folded? {
        let (header, turns) = TranscriptTurns.split(Array(transcript))
        let (old, recent) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        guard !old.isEmpty else { return nil }

        let summaryText = try await summarize(old, prompt: prompt, summarizer: summarizer)

        let entryId = "compaction-summary-\(UUID().uuidString)"
        let textSegmentId = "\(entryId)-text"
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
                promptName: prompt.name
            )
            return .response(
                Transcript.Response(
                    id: entryId,
                    assetIDs: [],
                    segments: [
                        .text(Transcript.TextSegment(id: textSegmentId, content: summaryText)),
                        .custom(CompactionSegment(content: content)),
                    ]
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
        for chunk in chunks {
            chunkSummaries.append(try await summarizeOnce(Self.render(chunk), prompt: prompt, summarizer: summarizer))
        }
        return try await reduce(chunkSummaries, prompt: prompt, summarizer: summarizer)
    }

    /// Combines `summaries` (the map step's chunk summaries) into one final
    /// summary — the map-reduce "reduce" step — recursing when the joined
    /// summaries would themselves exceed ``maxChunkTokens`` in a single
    /// summarizer call, so *no* summarizer call in this fold — map, reduce,
    /// or any re-reduce round — ever has to ingest more than
    /// ``maxChunkTokens`` worth of content, however many chunks the original
    /// span needed.
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
    /// - Throws: Whatever `summarizer.summarize(_:)` throws, unmodified.
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
            // No progress possible: every summary is already, on its own, at
            // or over maxChunkTokens, so grouping produced one singleton
            // group per summary. Recursing further would never terminate —
            // a single flat reduce, over budget or not, is the only option
            // left.
            return try await summarizeOnce(joined, prompt: prompt, summarizer: summarizer)
        }

        var nextRound: [String] = []
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
    private func summarizeOnce(
        _ content: String,
        prompt: CompactionPrompt,
        summarizer: any CompactionSummarizer
    ) async throws -> String {
        try await summarizer.summarize("\(prompt.text)\n\n---\n\n\(content)")
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
    /// labeled by role, in original order. `.instructions` never appears here
    /// (it is always the header, excluded from the old span before this is
    /// called).
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
