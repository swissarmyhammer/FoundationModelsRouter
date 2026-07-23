import Foundation
import FoundationModels
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
        private let responses: [String]

        init(responses: [String]) {
            self.responses = responses
        }

        func summarize(_ prompt: String) async throws -> String {
            defer { receivedPrompts.append(prompt) }
            let index = receivedPrompts.count
            return index < responses.count ? responses[index] : "unscripted-response-\(index)"
        }
    }

    /// A ``CompactionSummarizer`` that always throws, for asserting that a
    /// summarizer failure propagates rather than being silently swallowed.
    private struct ThrowingSummarizer: CompactionSummarizer {
        struct Failure: Error {}
        func summarize(_ prompt: String) async throws -> String { throw Failure() }
    }

    // MARK: - CompactionPrompt.default matches compaction_plan.md §2 verbatim

    @Test("CompactionPrompt.default's name and text match compaction_plan.md §2 verbatim")
    func defaultPromptMatchesPlanText() {
        let prompt = CompactionPrompt.default
        #expect(prompt.name == "router-default-v1")

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
            "2. Constraints & decisions — instructions, preferences, and decisions still",
            "3. Completed — work finished so far, with concrete outcomes.",
            "4. In progress — what is being worked on right now, and its exact state.",
            "5. Files & code — every file path touched or discussed, with the symbols,",
            "6. Errors & fixes — problems encountered and how they were (or were not)",
            "7. Next steps — the immediate next actions, in order, detailed enough to",
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

        guard case .custom(let customSegment) = response.segments[1], let segment = customSegment as? CompactionSegment
        else {
            Issue.record("expected the summary entry's second segment to be a .custom CompactionSegment")
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
        #expect(segment.content.promptName == "router-default-v1")

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
            case .custom(let segment) = response.segments.last,
            let compaction = segment as? CompactionSegment
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

    // MARK: - Compactor-level integration: Summarization wired in as the final stage

    @Test("Compactor.compact wires Summarization in as the final stage when the deterministic stages alone aren't enough")
    func compactorWiresInSummarizationAsFinalStage() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "large content ", count: 400)
        let turns = try (1...6).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let afterBoth = Compactor.estimatedTokenCount(of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        // A target below even the deterministic stages' best effort forces the
        // model-assisted stage to run.
        let limit = 1_000_000
        let budget = TokenBudget(limit: limit, trigger: 0.80, target: Double(afterBoth / 2) / Double(limit))

        // The two old turns' bigText content comfortably exceeds
        // Summarization's default maxChunkTokens (2000), so each becomes its
        // own chunk: 2 map calls, then 1 reduce call over their summaries —
        // the reduce call's result is what CompactionResult.summary carries.
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-1", "chunk-summary-2", "end-to-end summary"])
        let (resultTranscript, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(result.summary == "end-to-end summary")
        #expect(result.tokensBefore == tokensBefore)

        let entries = Array(resultTranscript)
        #expect(entries.first == instructions)
        guard case .response(let response) = entries[1], case .custom(let segment) = response.segments.last,
            let compaction = segment as? CompactionSegment
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
}
