import Foundation
import FoundationModels

/// A model the ``Summarization`` stage calls to condense text. It is one
/// stateless text-in, text-out call.
package protocol CompactionSummarizer: Sendable {
    /// Produces a complete text response to `prompt`. `maxTokens` is a hard
    /// ceiling on the reasoning and the answer together. A conformer must
    /// pass it to its model's output limit unchanged.
    ///
    /// - Throws: If summarization fails.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String
}

/// A failure of the ``Summarization`` stage that the summarizer itself did
/// not raise.
enum SummarizationError: Error, Equatable, LocalizedError {
    /// A summarizer call returned empty or whitespace-only text.
    case emptySummary

    var errorDescription: String? {
        switch self {
        case .emptySummary:
            return "the summarizer returned no text, so the fold has no summary to store"
        }
    }
}

/// The model-assisted compaction stage. It renders the folded span to text,
/// summarizes it with a ``CompactionPrompt`` through a ``CompactionSummarizer``,
/// and synthesizes the summary entry: a `.response` that carries the summary
/// text and its ``CompactionSegment``. It is async, so it does not conform to
/// ``CompactionStage``; ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
/// calls it directly, always with the original transcript.
public struct Summarization: Sendable, Equatable, Codable {
    /// This stage's name, as recorded in ``CompactionResult/stagesApplied``.
    public static let stageName = "Summarization"

    /// How many of the newest turns stay untouched. Defaults to `4`.
    public var keepRecentTurns: Int

    /// The estimated-token ceiling of one summarizer call's content. Above it
    /// the folded span is split into chunks that are summarized separately
    /// (map) and then combined (reduce). A single item is never split.
    public var maxChunkTokens: Int

    /// The fraction of a full ``maxChunkTokens`` of content that sizes
    /// ``maximumSummaryTokens``. Defaults to `0.25`.
    public var summaryTokenRatio: Double

    /// The tokens added to every call's summary allowance for the reasoning a
    /// model writes before its answer. Defaults to `8192`. It is a ceiling,
    /// not a target.
    public var reasoningTokenHeadroom: Int

    /// The floor, in tokens, of every call's summary allowance.
    public static let minimumSummaryTokens = 128

    /// The bytes the whole boundary text must stay under the folded span's
    /// content bytes so that the estimated token count drops by at least one.
    static let shrinkMarginBytes = Int(Compactor.charsPerTokenEstimate)

    /// The estimated UTF-8 size of one English word with its separator. It
    /// converts a byte budget to the word count stated to the model.
    static let summaryBytesPerWordEstimate = 6.0

    /// The share of a call's own content that the assembled prompt states as
    /// the size budget. `0.75` is the measured-best value.
    static let statedBudgetShareOfContent = 0.75

    /// Creates a summarization stage. Defaults: `keepRecentTurns` 4,
    /// `maxChunkTokens` 2000, `summaryTokenRatio` 0.25, `reasoningTokenHeadroom` 8192.
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

    /// The result of one fold: the folded transcript and the summary text.
    struct Folded: Sendable, Equatable {
        /// The folded transcript: the header, the summary entry, then the
        /// untouched recency window.
        let transcript: Transcript

        /// The synthesized summary text.
        let summary: String

        /// The summary entry's `Transcript.Entry.id`.
        let summaryEntryId: String

        /// Whether the last-resort cut removed text from ``summary``.
        let summaryCut: Bool
    }

    /// Folds the old span of `transcript` (everything but the header and the
    /// newest ``keepRecentTurns`` turns) into one summary entry.
    ///
    /// - Parameters:
    ///   - transcript: The original transcript to fold.
    ///   - prompt: The compaction prompt sent to `summarizer` before the content of every call.
    ///   - tokensBefore: The pipeline's measured size before any stage ran.
    ///   - priorStagesApplied: The stages applied before this one; ``stageName`` is appended.
    ///   - summarizer: The model called to condense text.
    ///   - pendingRuns: The summaries of the runs still running, in tracking order. Their rendering is charged against the span byte budget.
    /// - Returns: The fold, or `nil` when there is no old span to fold.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, or
    ///   ``SummarizationError/emptySummary`` when a call returns no text.
    func apply(
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

    /// The bytes the final summary may occupy so that the boundary entry
    /// shrinks the transcript: `spanBytes` minus ``shrinkMarginBytes`` minus
    /// `renderingBytes`. The result can be zero or negative.
    static func summaryByteBudget(forSpanBytes spanBytes: Int, pendingRunsRenderingBytes renderingBytes: Int) -> Int {
        spanBytes - shrinkMarginBytes - renderingBytes
    }

    /// Resolves a summary that may overrun `budgetBytes` into the text the
    /// fold stores. A summary inside the budget is stored as is. An oversized
    /// summary gets one condense re-ask; only then does ``cut(_:toCharacters:)``
    /// fire on the smaller candidate. A budget of zero or below skips the re-ask.
    ///
    /// - Returns: The text to store, and whether the cut removed text.
    /// - Throws: Whatever the condense re-ask throws, unmodified.
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
    /// `budgetBytes`, which must be positive.
    ///
    /// - Returns: The condensed answer, or `nil` when the model answered no text.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, unmodified.
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
    /// `budgetBytes` stated in words, then `summary`.
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

    /// Converts `bytes` into the word count stated to the model, at
    /// ``summaryBytesPerWordEstimate`` and never below one word.
    static func summaryBudgetWords(forBytes bytes: Int) -> Int {
        max(1, Int(Double(bytes) / summaryBytesPerWordEstimate))
    }

    // MARK: - Map-reduce summarization

    /// Summarizes `turns`. A span within ``maxChunkTokens`` takes one call. A
    /// longer span is split into turn-aligned chunks, each summarized (map),
    /// and the chunk summaries are combined by ``reduce(_:prompt:summarizer:)``.
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

    /// Combines `summaries` into one final summary. When the joined summaries
    /// exceed ``maxChunkTokens``, they are grouped with
    /// ``chunkStrings(_:maxTokens:)``, each group is condensed, and the
    /// function recurses on the smaller set. When grouping makes no progress,
    /// one flat reduce runs instead, so recursion always terminates.
    ///
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

    /// Makes one summarizer call: `prompt`'s instructions, the stated word
    /// budget, then `content`. Every map and reduce call of a fold goes
    /// through here.
    ///
    /// The calls one fold makes must stay serial. A session registers each
    /// call as the turn's one in-flight model call, so that a client stop can
    /// interrupt the fold. Concurrent calls would escape that stop.
    ///
    /// - Returns: The summarizer's answer, unchanged.
    /// - Throws: Whatever `summarizer.summarize(_:maxTokens:)` throws, or
    ///   ``SummarizationError/emptySummary`` when the answer holds no text.
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

    /// The characters that end a sentence.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Cuts `summary` to at most `limit` UTF-8 bytes. The cut falls, in
    /// order of preference, on the last whole numbered section
    /// (``sectionAlignedPrefix(of:withinBytes:)``), the last sentence or line
    /// end, the last word boundary, or the budget itself. A cut that would
    /// leave no text returns `summary` unchanged.
    ///
    /// - Returns: `summary` when it already fits, otherwise a prefix of it.
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

    /// Returns the last index of `text` that holds a line end, or a
    /// ``sentenceTerminators`` member at the end of the text or before
    /// whitespace. The whitespace condition skips periods inside values such
    /// as `3.5`. Returns `nil` when the text holds no boundary.
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

    /// Returns the longest prefix of `summary` that holds whole numbered
    /// sections and fits in `limit` bytes, with trailing whitespace dropped.
    /// Returns `nil` when `summary` has fewer than two section headers or
    /// when not even the first section fits. The result is never empty.
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

    /// Returns every index of `text` at which a numbered-section header line
    /// starts, in order. A header line opens flush left with ASCII digits, a
    /// period, and a space. An indented numbered line is not a header.
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

    /// Returns `true` when `line` opens a numbered section: one or more ASCII
    /// digits, then a period, then a space.
    private static func lineOpensSection(_ line: Substring) -> Bool {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.endIndex < line.endIndex, line[digits.endIndex] == "." else {
            return false
        }
        let afterPeriod = line.index(after: digits.endIndex)
        return afterPeriod < line.endIndex && line[afterPeriod] == " "
    }

    /// Converts `tokens` of the estimate back into characters. The inverse of
    /// ``estimatedTokens(of:)``.
    package static func characters(forEstimatedTokens tokens: Int) -> Int {
        Int(Double(tokens) * Compactor.charsPerTokenEstimate)
    }

    /// The ceiling, in tokens, one summarizer call generates under:
    /// `allowance` plus ``reasoningTokenHeadroom``.
    private func outputTokenCeiling(forSummaryAllowance allowance: Int) -> Int {
        allowance + reasoningTokenHeadroom
    }

    /// The summary allowance for a call that condenses `content`: the stated
    /// budget in estimated tokens, never below ``minimumSummaryTokens`` and
    /// never above ``maximumSummaryTokens``.
    private func summaryTokenAllowance(condensing content: String) -> Int {
        max(
            Self.minimumSummaryTokens,
            Int((Double(statedBudgetBytes(condensing: content)) / Compactor.charsPerTokenEstimate).rounded(.up)))
    }

    /// The stated budget, in UTF-8 bytes, for a call that condenses
    /// `content`: ``statedBudgetShareOfContent`` of the content's size, capped
    /// at what ``maximumSummaryTokens`` occupies in characters.
    private func statedBudgetBytes(condensing content: String) -> Int {
        min(
            Int(Double(content.utf8.count) * Self.statedBudgetShareOfContent),
            Self.characters(forEstimatedTokens: maximumSummaryTokens))
    }

    /// The allowance no single call's summary text may exceed: what a full
    /// ``maxChunkTokens`` of content earns under ``summaryTokenRatio``.
    private var maximumSummaryTokens: Int {
        summaryTokenAllowance(ingesting: maxChunkTokens)
    }

    /// ``summaryTokenRatio`` of `tokens`, rounded up and floored at
    /// ``minimumSummaryTokens``.
    private func summaryTokenAllowance(ingesting tokens: Int) -> Int {
        max(Self.minimumSummaryTokens, Int((Double(tokens) * summaryTokenRatio).rounded(.up)))
    }

    // MARK: - Chunking

    /// Splits `turns` into ordered groups that each stay at or under
    /// `maxTokens` in estimated tokens. A turn is never split; a lone
    /// oversized turn becomes its own group.
    static func chunk(_ turns: [TranscriptTurn], maxTokens: Int) -> [[TranscriptTurn]] {
        binPack(turns, maxTokens: maxTokens) { turn in
            Compactor.estimatedTokenCount(of: Transcript(entries: turn.entries))
        }
    }

    /// Splits `summaries` into ordered groups that each stay at or under
    /// `maxTokens` in estimated tokens. A summary is never split.
    static func chunkStrings(_ summaries: [String], maxTokens: Int) -> [[String]] {
        binPack(summaries, maxTokens: maxTokens) { estimatedTokens(of: $0) }
    }

    /// Greedily packs `items` into ordered groups. A new group starts when the
    /// next item would push the current group over `maxTokens`. An item is
    /// never split. `tokens` gives each item's estimated size.
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

    /// Estimates the size of `text` in tokens from its UTF-8 byte count at
    /// ``Compactor/charsPerTokenEstimate``. It is `package` so the compaction
    /// evals can report sizes in the same estimate.
    package static func estimatedTokens(of text: String) -> Int {
        Int((Double(text.utf8.count) / Compactor.charsPerTokenEstimate).rounded(.up))
    }

    // MARK: - Rendering

    /// Renders the entries of `turns` to plain text: one labeled line per
    /// entry, in order.
    private static func render(_ turns: [TranscriptTurn]) -> String {
        turns.flatMap(\.entries).compactMap(renderLine).joined(separator: "\n")
    }

    /// Renders `entry` to one labeled line (one line per call for
    /// `.toolCalls`), or `nil` for an entry kind with nothing to summarize.
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

    /// Returns the joined content of every `.text` segment in `segments`, in
    /// order. It is `internal` so the compaction evals can read seed
    /// transcripts through the same function.
    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined(separator: "\n")
    }
}
