import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task e3b6d6v (compaction epic — compaction_plan.md §1.3 stage 3,
/// §1.4, §2, build-order step 5): the model-assisted ``Summarization`` stage
/// and ``CompactionPrompt/default``.
///
/// A scripted ``CompactionSummarizer`` stands in for a real summarizer model:
/// it records every prompt it was asked to summarize and returns canned
/// responses in order, so these tests can assert exactly how many calls the
/// map-reduce made and what each call's assembled prompt contained, without
/// any model or network dependency.
///
/// Fixtures (`makeInstructions`/`makeTurn`/`makeTurns`) come from
/// `TranscriptFixtures` (Helpers/TranscriptTestHelpers.swift), shared with
/// `CompactionStageTests` and `CompactorPipelineTests`.
@Suite("Summarization stage: map-reduce, prompt assembly, CompactionSegment contents, and CompactionPrompt.default")
struct SummarizationStageTests {
    // MARK: - Scripted summarizer

    /// A ``CompactionSummarizer`` fully controlled by the test: never calls a
    /// real model, records every assembled prompt it receives (in call
    /// order), and returns canned responses from `responses`, cycling a
    /// final placeholder if more calls happen than responses were supplied.
    ///
    /// `@unchecked Sendable` is safe for the same reason as `SpikeBackend`
    /// (`CompactionSpikeTests`) and `MutableEntriesBackend`
    /// (`CompactionSegmentTests`): every access is sequential, driven by a
    /// single awaited test method, one call at a time — `Summarization.apply`
    /// never issues concurrent summarizer calls.
    private final class ScriptedSummarizer: CompactionSummarizer, @unchecked Sendable {
        private(set) var receivedPrompts: [String] = []

        /// The output ceiling each call was given, in call order — the bound a
        /// real summarizer would generate under.
        private(set) var receivedMaxTokens: [Int] = []
        private let responses: [String]

        init(responses: [String]) {
            self.responses = responses
        }

        func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
            defer {
                receivedPrompts.append(prompt)
                receivedMaxTokens.append(maxTokens)
            }
            let index = receivedPrompts.count
            return index < responses.count ? responses[index] : "unscripted-response-\(index)"
        }
    }

    /// A ``CompactionSummarizer`` that always throws, for asserting that a
    /// summarizer failure propagates rather than being silently swallowed.
    private struct ThrowingSummarizer: CompactionSummarizer {
        struct Failure: Error {}
        func summarize(_ prompt: String, maxTokens: Int) async throws -> String { throw Failure() }
    }

    /// A ``CompactionSummarizer`` whose answer is far larger than anything it
    /// could be asked to condense — a model that ignores the ceiling it was
    /// given, which is the one thing no output bound can prevent.
    private struct OversizedSummarizer: CompactionSummarizer {
        /// The summary every call returns, whatever it was asked to condense.
        let summary: String

        func summarize(_ prompt: String, maxTokens: Int) async throws -> String { summary }
    }

    /// The output ceiling ``Summarization`` should have computed for a call
    /// condensing `content`: the summary allowance that content earns, plus the
    /// reasoning headroom every call is given. Restated here rather than read
    /// off the stage, so these tests pin the arithmetic instead of comparing it
    /// against itself.
    ///
    /// - Parameters:
    ///   - content: The content the call was asked to condense.
    ///   - ratio: The stage's ``Summarization/summaryTokenRatio``.
    ///   - maxChunkTokens: The stage's ``Summarization/maxChunkTokens``.
    ///   - headroom: The stage's ``Summarization/reasoningTokenHeadroom``.
    /// - Returns: The expected ceiling, in tokens.
    private static func expectedCeiling(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int,
        headroom: Int
    ) -> Int {
        expectedSummaryAllowance(condensing: content, ratio: ratio, maxChunkTokens: maxChunkTokens) + headroom
    }

    /// The part of that ceiling the summary text itself may occupy: the
    /// content's own estimated size scaled by `ratio`, never below
    /// ``Summarization/minimumSummaryTokens`` and never above what a full
    /// `maxChunkTokens` of content earns.
    ///
    /// - Parameters:
    ///   - content: The content the call was asked to condense.
    ///   - ratio: The stage's ``Summarization/summaryTokenRatio``.
    ///   - maxChunkTokens: The stage's ``Summarization/maxChunkTokens``.
    /// - Returns: The expected summary allowance, in tokens.
    private static func expectedSummaryAllowance(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int
    ) -> Int {
        func allowance(ingesting tokens: Int) -> Int {
            max(Summarization.minimumSummaryTokens, Int((Double(tokens) * ratio).rounded(.up)))
        }
        return min(
            allowance(ingesting: maxChunkTokens),
            allowance(ingesting: Summarization.estimatedTokens(of: content)))
    }

    /// The content a summarizer call was asked to condense, recovered from the
    /// assembled prompt it received — the compaction instructions, then the
    /// separator, then the content (see `Summarization.summarizeOnce`).
    ///
    /// - Parameter prompt: The assembled prompt the call received.
    /// - Returns: The content part alone.
    private static func condensedContent(of prompt: String) throws -> String {
        try #require(prompt.components(separatedBy: "\n\n---\n\n").last)
    }

    // MARK: - CompactionPrompt.default matches compaction_plan.md §2 verbatim

    @Test("CompactionPrompt.default's name and text match compaction_plan.md §2 verbatim")
    func defaultPromptMatchesPlanText() {
        let prompt = CompactionPrompt.default
        #expect(prompt.name == "router-default-v2")

        let text = prompt.text
        #expect(
            text.contains(
                "You are compacting an agent conversation into a continuation summary. The\n"
                    + "summary will REPLACE the older conversation: whoever continues has no other\n"
                    + "memory of it, so anything you omit is lost. Be precise and dense. State only\n"
                    + "facts from the conversation — never invent, never infer beyond it."
            ))
        for heading in [
            "1. Intent — the user's request(s) and overall goal, in order given.",
            "2. Stated facts — every concrete fact stated in the conversation, each with",
            "3. Constraints & decisions — instructions, preferences, and decisions still",
            "4. Completed — work finished so far, with concrete outcomes.",
            "5. In progress — what is being worked on right now, and its exact state.",
            "6. Files & code — every file path touched or discussed, with the symbols,",
            "7. Errors & fixes — problems encountered and how they were (or were not)",
            "8. Next steps — the immediate next actions, in order, detailed enough to",
        ] {
            #expect(text.contains(heading))
        }
        #expect(
            text.contains(
                "Preserve safety- or security-relevant instructions VERBATIM\n"
                    + "   (files or data to avoid, operations not to perform, secret handling)."
            ))
        #expect(text.contains("No praise, no padding, no meta-commentary. Omit a section only if truly\nempty."))
    }

    @Test("CompactionPrompt.default gives a bare stated fact its own section, so a fold cannot record that a fact was stated without stating what it was")
    func defaultPromptKeepsBareStatedFacts() {
        // Pins the defect the gated eval measured on the `printer-and-supply-closet`
        // fixture: the summary read "1. Intent — Inform the assistant about the
        // location of spare toner cartridges. / 2. Constraints & decisions — None."
        // It recorded THAT a fact was communicated and discarded WHAT it was,
        // because a bare stated fact — a location, a code, a name, a number the
        // user simply told the assistant — is none of the other seven sections.
        // Compacting a conversation must not silently drop a fact stated in it
        // while leaving a plausible-looking summary behind.
        let text = CompactionPrompt.default.text
        #expect(text.contains("2. Stated facts — every concrete fact stated in the conversation, each with"))
        #expect(text.contains("Record WHAT was stated, never merely THAT something was stated"))
        #expect(text.contains("Never replace a stated value with a description of it."))
    }

    // MARK: - Segment contents: text segment + fully-populated CompactionSegment

    @Test("the synthesized summary entry carries the text segment and a fully-populated CompactionSegment")
    func summaryEntryCarriesFullyPopulatedSegment() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "old result \($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)

        let summarizer = ScriptedSummarizer(responses: ["the folded turns discussed a search query and its result"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: tokensBefore,
            priorStagesApplied: ["ToolOutputElision", "TurnTruncation"],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        #expect(unwrapped.summary == "the folded turns discussed a search query and its result")

        let entries = Array(unwrapped.transcript)
        // header (instructions) + synthesized summary entry + 4-turn recency window.
        guard case .response(let response) = entries[1] else {
            Issue.record("expected the entry right after the header to be the synthesized summary .response entry")
            return
        }
        #expect(response.segments.count == 2)
        guard case .text(let textSegment) = response.segments[0] else {
            Issue.record("expected the summary entry's first segment to be a .text segment")
            return
        }
        #expect(textSegment.content == unwrapped.summary)

        guard case .structure(let structuredSegment) = response.segments[1],
            let segment = try CompactionSegment(structuredSegment: structuredSegment)
        else {
            Issue.record("expected the summary entry's second segment to be a .structure CompactionSegment")
            return
        }
        // Turns 1 and 2 are old (turns 3...6 are the 4-turn recency window).
        #expect(segment.content.foldedEntryIds == turns[0].map(\.id) + turns[1].map(\.id))
        #expect(segment.content.liveWindowEntryIds.first == instructions.id)
        #expect(segment.content.liveWindowEntryIds.contains(response.id))
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }
        #expect(segment.content.liveWindowEntryIds.suffix(expectedRecentTail.count) == expectedRecentTail.map(\.id))
        #expect(segment.content.tokensBefore == tokensBefore)
        // tokensAfter is measured against a provisional build of the final
        // transcript (see Summarization.apply's own doc comment on the
        // two-pass build) — off by at most a digit or two of JSON-encoded
        // integer width from a fresh recount of the actual final transcript,
        // consistent with this estimate never being exact (compaction_plan.md
        // §1.5).
        #expect(abs(segment.content.tokensAfter - Compactor.estimatedTokenCount(of: unwrapped.transcript)) <= 1)
        #expect(segment.content.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(segment.content.promptName == "router-default-v2")

        // The recency window itself survives byte-identical.
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
    }

    // MARK: - Prompt assembly: default and custom prompt text sent verbatim

    @Test("the default prompt's text is sent to the summarizer verbatim, alongside the rendered folded span")
    func defaultPromptAssembledVerbatim() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...5).map { try TranscriptFixtures.makeTurn(index: $0, promptText: "distinctive-question-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        #expect(summarizer.receivedPrompts.count == 1)
        let sentPrompt = try #require(summarizer.receivedPrompts.first)
        #expect(sentPrompt.contains(CompactionPrompt.default.text))
        // Only turn 1 is old (keepRecentTurns: 4 out of 5 turns) — its distinctive
        // prompt text should appear in what got rendered and sent.
        #expect(sentPrompt.contains("distinctive-question-1"))
        #expect(!sentPrompt.contains("distinctive-question-2"))
    }

    @Test("a custom CompactionPrompt's text is sent to the summarizer verbatim and its name lands in the CompactionSegment")
    func customPromptUsedVerbatimAndNameRecorded() async throws {
        let customPrompt = CompactionPrompt(name: "my-custom-prompt-v7", text: "CUSTOM SUMMARIZATION INSTRUCTIONS — always list test commands.")
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["custom summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let folded = try await stage.apply(
            transcript,
            prompt: customPrompt,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        let sentPrompt = try #require(summarizer.receivedPrompts.first)
        #expect(sentPrompt.contains(customPrompt.text))
        #expect(!sentPrompt.contains(CompactionPrompt.default.text))

        guard case .response(let response) = Array(unwrapped.transcript)[1],
            case .structure(let segment) = response.segments.last,
            let compaction = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the synthesized summary entry to carry a CompactionSegment")
            return
        }
        #expect(compaction.content.promptName == "my-custom-prompt-v7")
    }

    // MARK: - Map-reduce chunking

    @Test("a folded span exceeding maxChunkTokens is split into multiple chunks, each summarized, then the chunk summaries are re-summarized into one final summary")
    func longSpanMapReducesAcrossChunks() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // Old turns are 1 and 2 (turns 3...6 are the keepRecentTurns: 4 window).
        // A maxChunkTokens equal to one old turn's own estimated size forces
        // each old turn into its own chunk: 2 chunks, not 1.
        let oneTurnTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))

        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", "final-combined-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        // 2 map calls (one per chunk) + 1 reduce call over their summaries.
        #expect(summarizer.receivedPrompts.count == 3)
        #expect(unwrapped.summary == "final-combined-summary")

        // The reduce call's assembled prompt carries both chunk summaries, not
        // the raw rendered turns.
        let reducePrompt = summarizer.receivedPrompts[2]
        #expect(reducePrompt.contains("chunk-summary-A"))
        #expect(reducePrompt.contains("chunk-summary-B"))

        // Each map call only ever saw its own chunk's content, not the other's.
        #expect(summarizer.receivedPrompts[0].contains("result-1"))
        #expect(!summarizer.receivedPrompts[0].contains("result-2"))
        #expect(summarizer.receivedPrompts[1].contains("result-2"))
        #expect(!summarizer.receivedPrompts[1].contains("result-1"))
    }

    @Test(
        "when the joined chunk summaries themselves exceed maxChunkTokens, the reduce step re-chunks and recurses into multiple rounds instead of one flat over-budget call"
    )
    func reduceRecursesWhenJoinedChunkSummariesExceedMaxChunkTokens() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        // 6 old turns (10 total, keepRecentTurns: 4) — each turn's own size
        // becomes maxChunkTokens, so every old turn is its own map chunk: 6
        // map calls.
        let turns = try (1...10).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let maxChunkTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))

        // Each map response is sized at roughly maxChunkTokens/4 estimated
        // tokens — small enough that several fit in one reduce group, but 6
        // of them combined comfortably exceed maxChunkTokens, forcing the
        // reduce step to group rather than flat-join everything into a
        // single over-budget call. The exact grouping is derived below via
        // `Summarization.chunkStrings` itself (the same function production
        // code uses) rather than hand-computed, since the "map-N-" prefix
        // shifts each item's exact byte size slightly.
        let mapResponseTokens = maxChunkTokens / 4
        let mapResponses = (1...6).map { "map-\($0)-" + String(repeating: "x", count: mapResponseTokens * 4) }
        let predictedGroups = Summarization.chunkStrings(mapResponses, maxTokens: maxChunkTokens)
        #expect(predictedGroups.count > 1)  // sanity: this scenario truly forces multiple groups

        let responses =
            mapResponses  // 6 map calls
            + predictedGroups.indices.map { "round1-group-\($0)" }  // one reduce call per predicted group
            + ["final-tree-reduced-summary"]  // 1 final reduce call
        let summarizer = ScriptedSummarizer(responses: responses)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        // 6 map calls + one reduce call per predicted group + 1 final reduce
        // call. The old (buggy) flat-reduce implementation would have made
        // exactly 7 calls (6 map + 1 flat reduce over all 6 at once, silently
        // exceeding maxChunkTokens) — this proves the tree-shaped recursion
        // actually ran instead.
        #expect(summarizer.receivedPrompts.count == 6 + predictedGroups.count + 1)
        #expect(unwrapped.summary == "final-tree-reduced-summary")

        // Each first-round reduce call combines exactly its predicted group's
        // map responses, never the full set of 6 at once.
        for (groupIndex, group) in predictedGroups.enumerated() {
            let callPrompt = summarizer.receivedPrompts[6 + groupIndex]
            for member in group {
                #expect(callPrompt.contains(member))
            }
            let outsiders = mapResponses.filter { !group.contains($0) }
            for outsider in outsiders {
                #expect(!callPrompt.contains(outsider))
            }
        }

        // The final call combines the first-round outputs, not the raw map
        // responses directly.
        let finalPrompt = summarizer.receivedPrompts.last!
        for groupIndex in predictedGroups.indices {
            #expect(finalPrompt.contains("round1-group-\(groupIndex)"))
        }
        #expect(!finalPrompt.contains(mapResponses[0]))
    }

    @Test(
        "when every chunk summary is already at or over maxChunkTokens on its own, the reduce step falls back to a single flat call instead of recursing forever"
    )
    func reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        // 3 old turns (7 total, keepRecentTurns: 4).
        let turns = try (1...7).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let maxChunkTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))

        // Each map response is deliberately oversized on its own (twice
        // maxChunkTokens) so the reduce step's chunkStrings groups each one
        // into its own singleton batch — no grouping progress is possible,
        // which must trigger the flat-fallback rather than recursing forever.
        let oversizedResponse = String(repeating: "y", count: maxChunkTokens * 2 * 4)
        #expect(Summarization.estimatedTokens(of: oversizedResponse) > maxChunkTokens)

        let responses = (1...3).map { _ in oversizedResponse } + ["flat-fallback-summary"]
        let summarizer = ScriptedSummarizer(responses: responses)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        // 3 map calls + exactly 1 flat-fallback reduce call — proves the
        // no-progress guard terminated immediately rather than recursing.
        #expect(summarizer.receivedPrompts.count == 4)
        #expect(unwrapped.summary == "flat-fallback-summary")
    }

    @Test("a short folded span within maxChunkTokens needs no chunking: exactly one summarizer call")
    func shortSpanNeedsNoChunking() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["single-call-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        let unwrapped = try #require(folded)

        #expect(summarizer.receivedPrompts.count == 1)
        #expect(unwrapped.summary == "single-call-summary")
    }

    // MARK: - Output bound: every summarizer call generates under a ceiling

    @Test(
        "a summarizer call is bounded by a share of the content it condenses, never left to the generation path's own default ceiling"
    )
    func summarizerCallIsBoundedByTheContentItCondenses() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "old span content ", count: 400)
        let turns = try (1...5).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        // One old turn, well within maxChunkTokens: exactly one call, whose
        // ceiling is the whole fold's.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        let ceiling = try #require(summarizer.receivedMaxTokens.first)
        #expect(summarizer.receivedMaxTokens.count == 1)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        #expect(
            ceiling
                == Self.expectedCeiling(
                    condensing: condensed,
                    ratio: stage.summaryTokenRatio,
                    maxChunkTokens: stage.maxChunkTokens,
                    headroom: stage.reasoningTokenHeadroom))
        // The point of the bound: a summary can never come back the size of
        // the span it replaces, which is what made a fold save almost nothing.
        // The bound is on the summary allowance, read back off the ceiling the
        // call was given — the reasoning headroom beside it is never summary
        // text, so it cannot make a summary longer.
        #expect(ceiling - stage.reasoningTokenHeadroom < Summarization.estimatedTokens(of: condensed))
    }

    @Test("a span too small to compress still gets the minimum a usable summary needs, not a truncated fragment")
    func shortSpanIsBoundedAtTheMinimum() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        let share = Int((Double(Summarization.estimatedTokens(of: condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(share < Summarization.minimumSummaryTokens)  // sanity: this span's share really is below the floor
        #expect(
            summarizer.receivedMaxTokens == [Summarization.minimumSummaryTokens + stage.reasoningTokenHeadroom])
    }

    @Test("every call a chunked fold makes is bounded by its own content, the reduce round over the chunk summaries included")
    func everyCallOfAChunkedFoldIsBounded() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // One old turn per chunk (as `longSpanMapReducesAcrossChunks` sets up):
        // 2 map calls, then 1 reduce call over their summaries.
        let oneTurnTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", "final-combined-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        #expect(summarizer.receivedMaxTokens.count == 3)
        for (index, ceiling) in summarizer.receivedMaxTokens.enumerated() {
            let condensed = try Self.condensedContent(of: summarizer.receivedPrompts[index])
            #expect(
                ceiling
                    == Self.expectedCeiling(
                        condensing: condensed,
                        ratio: stage.summaryTokenRatio,
                        maxChunkTokens: stage.maxChunkTokens,
                        headroom: stage.reasoningTokenHeadroom))
        }
    }

    @Test(
        "the reduce step's no-progress flat fallback ingests more than maxChunkTokens, and its answer is still bounded by what a full chunk earns"
    )
    func reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        // 3 old turns (7 total, keepRecentTurns: 4), each its own map chunk —
        // the same shape as `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible`,
        // sized large enough that a quarter of the joined summaries is well
        // clear of the minimumSummaryTokens floor, so the ceiling this asserts
        // is the cap doing the work rather than the floor.
        let bigText = String(repeating: "old span content ", count: 400)
        let turns = try (1...7).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let maxChunkTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))
        // Twice the chunk ceiling each, so `chunkStrings` can pair no two of
        // them and `reduce` takes its no-progress fallback over the whole
        // joined set — the one call that must ingest more than maxChunkTokens.
        let oversizedSummaryTokens = maxChunkTokens * 2
        let oversizedResponse = String(
            repeating: "y", count: oversizedSummaryTokens * Int(Compactor.charsPerTokenEstimate))
        let responses = (1...3).map { _ in oversizedResponse } + ["flat-fallback-summary"]
        let summarizer = ScriptedSummarizer(responses: responses)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        // 3 map calls + exactly 1 flat-fallback reduce call.
        #expect(summarizer.receivedMaxTokens.count == 4)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.last))
        // sanity: the fallback really does ingest more than a chunk's worth.
        #expect(Summarization.estimatedTokens(of: condensed) > maxChunkTokens)

        let ceiling = try #require(summarizer.receivedMaxTokens.last)
        #expect(
            ceiling
                == Self.expectedCeiling(
                    condensing: condensed,
                    ratio: stage.summaryTokenRatio,
                    maxChunkTokens: stage.maxChunkTokens,
                    headroom: stage.reasoningTokenHeadroom))
        // The ratio alone would let this one call's summary allowance grow with
        // the number of chunk summaries joined into it, which is exactly how the
        // final summary of an arbitrarily long span escaped its bound.
        let unbounded = Int((Double(Summarization.estimatedTokens(of: condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(ceiling - stage.reasoningTokenHeadroom < unbounded)
    }

    @Test(
        "a single turn too large to fit a chunk ingests more than maxChunkTokens, and its answer is still bounded by what a full chunk earns"
    )
    func unsplittableTurnCallIsBoundedDespiteIngestingMoreThanAChunk() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "old span content ", count: 400)
        let turns = try (1...5).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // One old turn (5 turns, keepRecentTurns: 4), and `chunk(_:maxTokens:)`
        // never splits a turn — so a chunk ceiling well under that turn's own
        // size still yields a single, oversized chunk and a single map call.
        let oneTurnTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))
        let chunkCeilingDivisor = 8
        let maxChunkTokens = oneTurnTokens / chunkCeilingDivisor

        let summarizer = ScriptedSummarizer(responses: ["single-oversized-chunk-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        #expect(summarizer.receivedMaxTokens.count == 1)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        // sanity: the lone turn really is bigger than a chunk may be.
        #expect(Summarization.estimatedTokens(of: condensed) > maxChunkTokens)

        let ceiling = try #require(summarizer.receivedMaxTokens.first)
        #expect(
            ceiling
                == Self.expectedCeiling(
                    condensing: condensed,
                    ratio: stage.summaryTokenRatio,
                    maxChunkTokens: stage.maxChunkTokens,
                    headroom: stage.reasoningTokenHeadroom))
        let unbounded = Int((Double(Summarization.estimatedTokens(of: condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(ceiling - stage.reasoningTokenHeadroom < unbounded)
    }

    // MARK: - Reasoning headroom: a call's ceiling holds the think block as well as the answer

    @Test(
        "a summarizer call is given the reasoning headroom on top of its summary allowance, so a model that thinks before it answers still reaches the answer"
    )
    func summarizerCallCarriesReasoningHeadroomAboveItsSummaryAllowance() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "old span content ", count: 400)
        let turns = try (1...5).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        let ceiling = try #require(summarizer.receivedMaxTokens.first)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        let allowance = Self.expectedSummaryAllowance(
            condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens)
        // The two amounts are separate, and the ceiling is their sum: the ratio
        // sizes the summary text, and the headroom pays for the reasoning a
        // model writes before that text starts.
        #expect(ceiling == allowance + stage.reasoningTokenHeadroom)
        #expect(ceiling > allowance)
    }

    @Test("a non-default reasoningTokenHeadroom reaches the ceiling every summarizer call is given")
    func nonDefaultReasoningHeadroomReachesTheSummarizerCall() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let headroom = 777
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000, reasoningTokenHeadroom: headroom)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        // This span is small enough that the floor decides the allowance, so
        // the number the summarizer was handed states the headroom exactly.
        #expect(summarizer.receivedMaxTokens == [Summarization.minimumSummaryTokens + headroom])
    }

    @Test("the default reasoning headroom is at least the ceiling this repository measured a reasoning turn needs")
    func defaultReasoningHeadroomMeetsTheMeasuredCeiling() {
        // `GatedRealModelBudget` records the measurement: the gated model always
        // writes a `<think>` block first, a ceiling of 512 leaves its answer
        // empty, and 4096 does not. A summarizer call is one such turn, so its
        // headroom may never be smaller than the value that measurement names.
        #expect(Summarization().reasoningTokenHeadroom >= GatedRealModelBudget.responseTokenCeiling)
    }

    // MARK: - Nothing to fold: Summarization is a no-op (Compactor's fallback path)

    @Test("when every turn is inside the recency window, there is no old span to fold: Summarization returns nil")
    func nothingToFoldReturnsNil() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(2)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: [])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let folded = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )

        #expect(folded == nil)
        #expect(summarizer.receivedPrompts.isEmpty)
    }

    // MARK: - Summarizer failure propagates

    @Test("a throwing summarizer's error propagates out of Summarization.apply rather than being swallowed")
    func summarizerFailurePropagates() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: ThrowingSummarizer.Failure.self) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [],
                summarizer: ThrowingSummarizer()
            )
        }
    }

    // MARK: - An empty summarizer answer is a fold failure

    @Test("a summarizer answer with no text is reported as a fold failure, never stored as the fold's summary")
    func emptySummarizerAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: [""])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [],
                summarizer: summarizer
            )
        }
    }

    @Test("a summarizer answer of whitespace alone is reported the same way: it carries no summary either")
    func whitespaceOnlySummarizerAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["  \n\t  "])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [],
                summarizer: summarizer
            )
        }
    }

    @Test("an empty answer from the reduce round is reported too, so every call of a chunked fold is checked")
    func emptyReduceRoundAnswerIsReported() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // One old turn per chunk (as `longSpanMapReducesAcrossChunks` sets up):
        // 2 map calls that answer, then 1 reduce call that answers nothing.
        let oneTurnTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", ""])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await stage.apply(
                transcript,
                prompt: .default,
                tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [],
                summarizer: summarizer
            )
        }
        #expect(summarizer.receivedPrompts.count == 3)
    }

    // MARK: - Compactor-level integration: Summarization wired in as the final stage

    /// How many turns ``makeModelAssistedFoldFixture()`` builds.
    private static let foldFixtureTurnCount = 6

    /// How many times each of a fixture turn's three text fields repeats its
    /// content phrase — large enough that one turn on its own exceeds
    /// ``Summarization/maxChunkTokens``'s default, so the default chunking
    /// gives each old turn a summarizer call of its own.
    private static let foldFixtureRepeatsPerTurn = 400

    /// The context-window size ``makeModelAssistedFoldFixture()``'s budget is
    /// stated against — far larger than the fixture, so the target fraction
    /// alone decides what the pipeline has to do.
    private static let foldFixtureBudgetLimit = 1_000_000

    /// The fraction of ``foldFixtureBudgetLimit`` a fold is triggered at —
    /// irrelevant to these tests, which call `compact` directly rather than
    /// wait for a trigger, but a ``TokenBudget`` requires one.
    private static let foldFixtureTrigger = 0.80

    /// A ``Summarization/maxChunkTokens`` wide enough to hold any fixture span
    /// here in a single summarizer call — the non-default setting a test uses
    /// to prove chunking read the knob it was given.
    private static let wholeSpanChunkTokens = 1_000_000

    /// The fixture the `Compactor.compact` tests below share: a header, six
    /// turns whose content is far too large for the deterministic stages to
    /// land, and a budget whose target sits below even their best effort — so
    /// the pipeline always falls through to ``Summarization``.
    ///
    /// Each turn's text names its own index, so a test can tell from a
    /// summarizer's assembled prompt which turns the fold condensed.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to fold it against.
    private static func makeModelAssistedFoldFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...foldFixtureTurnCount).map { index -> [Transcript.Entry] in
            let text = String(repeating: "large content turn-\(index) ", count: foldFixtureRepeatsPerTurn)
            return try TranscriptFixtures.makeTurn(
                index: index, promptText: text, toolOutputText: text, responseText: text)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // A target below even the deterministic stages' best effort forces the
        // model-assisted stage to run.
        let afterBoth = Compactor.estimatedTokenCount(of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        let budget = TokenBudget(
            limit: foldFixtureBudgetLimit,
            trigger: foldFixtureTrigger,
            target: Double(afterBoth / 2) / Double(foldFixtureBudgetLimit)
        )
        return (turns, transcript, budget)
    }

    @Test("Compactor.compact wires Summarization in as the final stage when the deterministic stages alone aren't enough")
    func compactorWiresInSummarizationAsFinalStage() async throws {
        let (turns, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)

        // The two old turns' content comfortably exceeds Summarization's
        // default maxChunkTokens (2000), so each becomes its own chunk: 2 map
        // calls, then 1 reduce call over their summaries — the reduce call's
        // result is what CompactionResult.summary carries.
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-1", "chunk-summary-2", "end-to-end summary"])
        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(result.summary == "end-to-end summary")
        #expect(result.tokensBefore == tokensBefore)

        let entries = Array(resultTranscript)
        #expect(entries.first == TranscriptFixtures.makeInstructions())
        guard case .response(let response) = entries[1], case .structure(let segment) = response.segments.last,
            let compaction = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the compacted transcript's second entry to carry a CompactionSegment")
            return
        }
        #expect(compaction.content.promptName == CompactionPrompt.default.name)
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
    }

    @Test("Compactor.compact with no summarizer degrades to the deterministic stages: no Summarization, no summary")
    func compactorWithNoSummarizerDegradesToModelFreePipeline() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "big ", count: 2000)
        let turns = try (1...2).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let limit = 1_000_000
        let budget = TokenBudget(limit: limit, trigger: 0.80, target: Double(tokensBefore / 2) / Double(limit))

        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
    }

    @Test(
        "a fold whose summary leaves the transcript no smaller than it was is not applied: the original transcript comes back, with the shortfall reported"
    )
    func foldThatDoesNotShrinkTheTranscriptIsNotApplied() async throws {
        // The same fixture `compactorWiresInSummarizationAsFinalStage` folds —
        // a target below even the deterministic stages' best effort, so the
        // model-assisted stage runs — differing only in what the summarizer
        // answers.
        let (_, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)

        // A summary bigger than the whole transcript it would replace — sized
        // off `tokensBefore` itself, so the scenario holds however the
        // fixtures above are resized: the fold "succeeds" and leaves the
        // session worse off than before.
        let summarizer = OversizedSummarizer(summary: String(repeating: "verbose summary ", count: tokensBefore))
        #expect(Summarization.estimatedTokens(of: summarizer.summary) > tokensBefore)  // sanity: the fold really does grow it

        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        // Reported exactly like the oversized-tail case: the original
        // transcript, no stages applied, and `tokensAfter` naming the size of
        // what is actually being returned.
        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == tokensBefore)
    }

    @Test("Compactor.compact reports an empty summary rather than apply a fold whose boundary would carry no text")
    func compactorReportsAnEmptySummaryRatherThanApplyIt() async throws {
        // The same fixture `compactorWiresInSummarizationAsFinalStage` folds,
        // differing only in what the summarizer answers: nothing at all.
        let (_, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let summarizer = ScriptedSummarizer(responses: [""])

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)
        }
    }

    @Test("a supplied summarizer is never invoked when the deterministic stages alone already land under target")
    func summarizerNotInvokedWhenDeterministicStagesSuffice() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "small result") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let limit = 1_000_000
        let budget = TokenBudget(limit: limit, trigger: 0.80, target: Double(tokensBefore * 2) / Double(limit))

        let summarizer = ScriptedSummarizer(responses: [])
        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(summarizer.receivedPrompts.isEmpty)
    }

    // MARK: - The stage's own tuning, set through Compactor.compact

    @Test("a non-default summaryTokenRatio set through Compactor.compact reaches the ceiling the summarizer call is given")
    func compactCarriesSummaryTokenRatioIntoTheSummarizerCall() async throws {
        let (_, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let summarizer = ScriptedSummarizer(responses: [])
        let defaults = Summarization()
        let ratio = 0.5

        let (_, result) = try await Compactor.compact(
            transcript,
            budget: budget,
            summarizer: summarizer,
            summarization: Summarization(summaryTokenRatio: ratio)
        )

        #expect(result.stagesApplied.last == Summarization.stageName)

        // The first call is a map call over one whole old turn, whose content
        // is large enough that the ratio — not the minimumSummaryTokens floor —
        // decides the ceiling, so the knob is visible in the number the
        // summarizer was handed.
        let firstPrompt = try #require(summarizer.receivedPrompts.first)
        let firstContent = try Self.condensedContent(of: firstPrompt)
        let firstCeiling = try #require(summarizer.receivedMaxTokens.first)
        #expect(
            firstCeiling
                == Self.expectedCeiling(
                    condensing: firstContent,
                    ratio: ratio,
                    maxChunkTokens: defaults.maxChunkTokens,
                    headroom: defaults.reasoningTokenHeadroom))
        // And it is that knob, not the default, that produced it.
        #expect(
            firstCeiling
                != Self.expectedCeiling(
                    condensing: firstContent,
                    ratio: defaults.summaryTokenRatio,
                    maxChunkTokens: defaults.maxChunkTokens,
                    headroom: defaults.reasoningTokenHeadroom))
    }

    @Test("a non-default maxChunkTokens set through Compactor.compact reaches the fold's map-reduce chunking")
    func compactCarriesMaxChunkTokensIntoTheChunking() async throws {
        let (_, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let summarizer = ScriptedSummarizer(responses: ["one-shot summary"])

        let (_, result) = try await Compactor.compact(
            transcript,
            budget: budget,
            summarizer: summarizer,
            summarization: Summarization(maxChunkTokens: Self.wholeSpanChunkTokens)
        )

        // The default 2000 gives each of the two old turns a chunk of its own —
        // 2 map calls, then a reduce call over their summaries, as
        // `compactorWiresInSummarizationAsFinalStage` asserts. A ceiling wide
        // enough for the whole span condenses both turns in one call instead.
        #expect(summarizer.receivedPrompts.count == 1)
        let content = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        #expect(content.contains("turn-1"))
        #expect(content.contains("turn-2"))
        #expect(result.summary == "one-shot summary")
    }

    @Test("a non-default keepRecentTurns set through Compactor.compact reaches the fold's recency window")
    func compactCarriesKeepRecentTurnsIntoTheFold() async throws {
        let (turns, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let summarizer = ScriptedSummarizer(responses: [])
        let keepRecentTurns = 2

        let (resultTranscript, _) = try await Compactor.compact(
            transcript,
            budget: budget,
            summarizer: summarizer,
            summarization: Summarization(keepRecentTurns: keepRecentTurns)
        )

        // The default 4 keeps turns 3...6 and folds turns 1 and 2. A window of
        // 2 keeps only turns 5 and 6, so the tail the fold left untouched is
        // shorter and turns 3 and 4 are inside the span the summarizer read.
        let expectedRecentTail = turns.suffix(keepRecentTurns).flatMap { $0 }
        let entries = Array(resultTranscript)
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
        // The header, the one synthesized summary entry, and that tail — and
        // nothing else. Counting the whole transcript is what makes the window
        // narrower rather than merely ending in the same turns: the default's
        // wider window would leave turns 3 and 4 in front of the tail here.
        #expect(entries.count == 1 + 1 + expectedRecentTail.count)
        #expect(summarizer.receivedPrompts.contains { $0.contains("turn-4") })
        #expect(!summarizer.receivedPrompts.contains { $0.contains("turn-5") })
    }
}
