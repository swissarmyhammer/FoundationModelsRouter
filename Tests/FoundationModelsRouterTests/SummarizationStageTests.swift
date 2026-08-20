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
    /// STATED budget's own size in estimated tokens, never below
    /// ``Summarization/minimumSummaryTokens`` — so a call's ceiling always
    /// covers the ask its prompt states, the invariant the 1B re-baseline of
    /// 2026-08-20 measured failing when the allowance was still a quarter of
    /// the content while the prompt asked for three quarters. Restated here
    /// rather than read off the stage, so these tests pin the arithmetic
    /// instead of comparing it against itself.
    ///
    /// - Parameters:
    ///   - content: The content the call was asked to condense.
    ///   - ratio: The stage's ``Summarization/summaryTokenRatio``, which
    ///     sizes the cap alone.
    ///   - maxChunkTokens: The stage's ``Summarization/maxChunkTokens``.
    /// - Returns: The expected summary allowance, in tokens.
    private static func expectedSummaryAllowance(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int
    ) -> Int {
        let statedBytes = expectedStatedBudgetBytes(
            condensing: content, ratio: ratio, maxChunkTokens: maxChunkTokens)
        return max(
            Summarization.minimumSummaryTokens,
            Int((Double(statedBytes) / Compactor.charsPerTokenEstimate).rounded(.up)))
    }

    /// The bytes the stated budget should name for a call condensing
    /// `content`: the stated share of the content, capped at what a full
    /// `maxChunkTokens` of content earns at `ratio` so the final summary of a
    /// conversation of any length stays bounded. Restated here rather than
    /// read off the stage, so these tests pin the arithmetic instead of
    /// comparing it against itself.
    ///
    /// - Parameters:
    ///   - content: The content the call was asked to condense.
    ///   - ratio: The stage's ``Summarization/summaryTokenRatio``.
    ///   - maxChunkTokens: The stage's ``Summarization/maxChunkTokens``.
    /// - Returns: The expected stated budget, in UTF-8 bytes.
    private static func expectedStatedBudgetBytes(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int
    ) -> Int {
        let statedShare = 0.75
        let capTokens = max(Summarization.minimumSummaryTokens, Int((Double(maxChunkTokens) * ratio).rounded(.up)))
        return min(
            Int(Double(content.utf8.count) * statedShare),
            Summarization.characters(forEstimatedTokens: capTokens))
    }

    /// The byte budget the fold's FINAL summary must fit for the boundary
    /// entry to shrink the transcript (task ^xx02yn6): the folded span's own
    /// content bytes, minus the shrink margin one estimated token costs, minus
    /// the pending-runs rendering the boundary entry carries beside the
    /// summary. Restated here rather than read off the stage, so these tests
    /// pin the arithmetic instead of comparing it against itself.
    ///
    /// - Parameters:
    ///   - oldTurns: The folded span's turns, each as its own entries.
    ///   - renderingBytes: The pending-runs rendering's UTF-8 size — `0`, the
    ///     default, when the fold parks no runs.
    /// - Returns: The expected budget, in UTF-8 bytes.
    private static func expectedSummaryByteBudget(
        foldingOld oldTurns: [[Transcript.Entry]],
        renderingBytes: Int = 0
    ) -> Int {
        let shrinkMarginBytes = 4
        return spanContentBytes(of: oldTurns) - shrinkMarginBytes - renderingBytes
    }

    /// The content bytes of a folded span's turns — the same measure
    /// `Compactor`'s did-not-shrink guard sums over the span's entries.
    ///
    /// - Parameter oldTurns: The folded span's turns, each as its own entries.
    /// - Returns: The span's content size, in UTF-8 bytes.
    private static func spanContentBytes(of oldTurns: [[Transcript.Entry]]) -> Int {
        oldTurns.flatMap { $0 }.reduce(0) { $0 + Compactor.contentByteCount(of: $1) }
    }

    /// The word count the stage should state to a call whose summary budget is
    /// `bytes`: the budget divided by the estimated UTF-8 size of one English
    /// word with its separator. Restated here rather than read off the stage,
    /// so these tests pin the arithmetic instead of comparing it against
    /// itself.
    ///
    /// - Parameter bytes: The budget, in UTF-8 bytes.
    /// - Returns: The expected word count.
    private static func expectedBudgetWords(forBytes bytes: Int) -> Int {
        let bytesPerWord = 6.0
        return max(1, Int(Double(bytes) / bytesPerWord))
    }

    /// Folds `turns` with `stage` and `prompt`, and returns the assembled
    /// prompt of every summarizer call the fold made, in call order.
    ///
    /// The turns come in rather than being built here because a caller sizing
    /// `stage.maxChunkTokens` against one turn has to measure that turn before
    /// the fold runs.
    ///
    /// - Parameters:
    ///   - turns: The turns to fold, each as its own entries.
    ///   - stage: The stage to fold with.
    ///   - prompt: The compaction prompt to fold with.
    ///   - responses: What the scripted summarizer answers, one per call.
    /// - Returns: The assembled prompts, in call order.
    /// - Throws: Whatever the fold throws.
    private static func assembledPrompts(
        folding turns: [[Transcript.Entry]],
        with stage: Summarization,
        prompt: CompactionPrompt,
        answering responses: [String]
    ) async throws -> [String] {
        try await foldOutcome(folding: turns, with: stage, prompt: prompt, answering: responses).prompts
    }

    /// Folds `turns` with `stage` and `prompt`, and returns both what the fold
    /// stored and the assembled prompt of every summarizer call it made.
    ///
    /// What a fold STORES is not what its summarizer ANSWERED — the stage cuts
    /// an answer down to the share of its content that call may retain — so a test about that
    /// bound has to read the fold's own result rather than the scripted answer
    /// it started from.
    ///
    /// - Parameters:
    ///   - turns: The turns to fold, each as its own entries.
    ///   - stage: The stage to fold with.
    ///   - prompt: The compaction prompt to fold with.
    ///   - responses: What the scripted summarizer answers, one per call.
    /// - Returns: What the fold stored, the assembled prompts in call order,
    ///   and the ceiling each call was given.
    /// - Throws: Whatever the fold throws.
    private static func foldOutcome(
        folding turns: [[Transcript.Entry]],
        with stage: Summarization,
        prompt: CompactionPrompt,
        answering responses: [String]
    ) async throws -> (folded: Summarization.Folded?, prompts: [String], ceilings: [Int]) {
        let transcript = Transcript(entries: [TranscriptFixtures.makeInstructions()] + turns.flatMap { $0 })
        let summarizer = ScriptedSummarizer(responses: responses)
        let folded = try await stage.apply(
            transcript,
            prompt: prompt,
            tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [],
            summarizer: summarizer
        )
        return (folded, summarizer.receivedPrompts, summarizer.receivedMaxTokens)
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
        #expect(prompt.name == "router-default-v3")

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

    @Test("CompactionPrompt.default states the size budget and demands verbatim identifiers, names and values")
    func defaultPromptStatesTheBudgetAndDemandsVerbatimValues() {
        // Task ^xx02yn6: the 2-seed Qwen probe of 2026-08-20 measured a model
        // that was never given a size it could comply with, and answers that
        // abstracted values ("then stated the staging database port") wherever
        // the demand was soft. The default instructions now state both: the
        // size budget each request carries, and the demand that every value be
        // copied exactly as it appears.
        let text = CompactionPrompt.default.text
        #expect(text.contains("size budget"))
        // The budget must read as an aim, never as a rule a reasoning model
        // deliberates over — the instrumented Qwen probe of 2026-08-20
        // measured "at most" phrasing emptying 2 of 2 answers.
        #expect(text.contains("without counting words"))
        #expect(text.contains("EXACTLY as it"))
        #expect(text.contains("character for character"))
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
        #expect(segment.content.promptName == "router-default-v3")

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

    // MARK: - Segment flattening: the text a fold reads out of an entry

    @Test("flattening an entry's segments joins every text segment in order with a newline and drops the segments that carry no text")
    func flatteningJoinsTextSegmentsAndDropsTheRest() throws {
        // `Summarization.text(of:)` is what turns an entry into the line a
        // summarizer reads, and the compaction eval dataset reads its seed
        // transcripts through the same function so it measures the text a fold
        // really shows the model. Two callers make the contract worth stating
        // outright rather than inferring it from an assembled prompt.
        let structureContent = try GeneratedContent(json: #"{"tempF":72}"#)
        let segments: [Transcript.Segment] = [
            .text(Transcript.TextSegment(id: "s-1", content: "first line")),
            .structure(Transcript.StructuredSegment(id: "s-2", schemaName: "Weather", content: structureContent)),
            .text(Transcript.TextSegment(id: "s-3", content: "second line")),
        ]

        #expect(Summarization.text(of: segments) == "first line\nsecond line")
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

    // MARK: - The final summary is bounded against the span, and the budget is stated to the model

    /// One sentence a scripted summarizer answers with, repeated to build an
    /// answer that overruns the span byte budget its fold earns.
    ///
    /// It ends in a period and a space, so a cut at a sentence boundary has
    /// somewhere to land.
    private static let summarySentence =
        "The service reads its whole configuration from environment variables at startup. "

    /// How many times ``summarySentence`` repeats to make one over-long answer
    /// — far past the span byte budget every small fixture span here earns.
    private static let summarySentenceRepeats = 12

    /// The tool-output text that makes a folded span's byte budget larger
    /// than an answer of ``underSpanBudgetAnswerRepeats`` sentences, while
    /// that answer still overruns the compression allowance the call
    /// generated under — the band the old ratio cut took and the span bound
    /// leaves alone (task ^xx02yn6).
    private static let largeSpanToolOutput = String(repeating: summarySentence, count: 40)

    /// How many times ``summarySentence`` repeats to make an answer that sits
    /// ABOVE the generation allowance and BELOW the span byte budget a
    /// ``largeSpanToolOutput`` span earns.
    private static let underSpanBudgetAnswerRepeats = 20

    /// The tool-output text that gives a small fixture span a byte budget of
    /// a few hundred bytes — wide enough that a short condensed answer fits
    /// it, and narrow enough that a ``summarySentenceRepeats`` answer
    /// overruns it.
    private static let condensableSpanToolOutput = String(repeating: summarySentence, count: 2)

    /// The tool-output text that sizes a span so its byte budget keeps some
    /// whole sections of a ``sectionedAnswerSection(index:)`` answer and not
    /// all of them, so the section-aligned cut point is observable.
    private static let sectionedCutSpanToolOutput = String(repeating: summarySentence, count: 6)

    /// One numbered section of a scripted sectioned answer, in the shape the
    /// default prompt's scaffold produces: a flush-left `N. ` header, then
    /// full sentences.
    ///
    /// Every index the tests use is a single digit, so each section holds the
    /// same byte count and the section a cut keeps or drops is deterministic.
    ///
    /// - Parameter index: The section's number.
    /// - Returns: The section, one line.
    private static func sectionedAnswerSection(index: Int) -> String {
        "\(index). Topic \(index) — the fold keeps the facts of kind \(index) here. "
            + "The section states them in full sentences. Each fact keeps its stated value. It stays whole."
    }

    /// How many numbered sections a scripted sectioned answer carries — the
    /// default prompt's own count.
    private static let sectionedAnswerSectionCount = 8

    /// How many whole sections of that answer fit the cut bound a
    /// minimum-allowance call earns. The test asserts both sides of this
    /// count as sanity, so a change to the section text fails loudly.
    private static let keptSectionCount = 3

    @Test("the assembled prompt carries the caller's instructions, the stated size budget, and the content")
    func theAssembledPromptStatesTheSizeBudget() async throws {
        // The budget is stated per call, as a target in words (task
        // ^xx02yn6). `^azd033m` measured a hard character directive against
        // Muse-Glimmer — "write at most N characters ... Compress hard" —
        // and that model spent the whole ceiling inside its `<think>` block.
        // The standard model is Qwen3.8-27B now, and the 2-seed probe of
        // 2026-08-20 measured the opposite defect: a model that was never
        // given a size wrote 2.2-3.0 KB answers, and the old ratio cut then
        // discarded the fact sections. So the prompt states the budget as a
        // target, and the span bound below is still enforced in code, where
        // no model has a say in it.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let prompts = try await Self.assembledPrompts(
            folding: try TranscriptFixtures.makeTurns(5),
            with: stage,
            prompt: .default,
            answering: ["summary"]
        )

        let assembled = try #require(prompts.first)
        let condensed = try Self.condensedContent(of: assembled)
        // The stated budget is a share of the CONTENT the call condenses —
        // near the span byte budget the fold enforces — never the compression
        // allowance. The instrumented Qwen probes of 2026-08-20 measured why:
        // an allowance-derived 85-word target against an eight-section
        // verbatim-fact demand is unsatisfiable, and the thinking model spent
        // whole 4224- and 8320-token ceilings drafting and word-counting
        // inside `<think>`, answering EMPTY on 2 of 2 seeds both times.
        let words = Self.expectedBudgetWords(
            forBytes: Self.expectedStatedBudgetBytes(
                condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens))
        // "about N words ... never count": the same probes captured the model
        // counting its draft word by word against the target, so the line
        // forbids the verification outright as its own rule.
        #expect(
            assembled
                == "\(CompactionPrompt.default.text)\n\nSize budget: about \(words) words. "
                + "This is a rough ceiling — never count or verify the length; a near miss is fine."
                + "\n\n---\n\n\(condensed)"
        )
    }

    @Test("the ceiling a call generates under covers the stated budget, so a compliant answer is never truncated mid-write")
    func theCeilingCoversTheStatedBudget() async throws {
        // The invariant the 1B re-baseline of 2026-08-20 measured failing:
        // the prompt asked for three quarters of the content while the
        // generation allowance was still a quarter of it, so the ceiling
        // ended the answer mid-list before the facts stated late in the span
        // — 5 of 7 summaries lost their fact to the truncation, not to the
        // model. The allowance is sized from the stated budget now, so an
        // answer that complies with the ask always fits the generation room.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.largeSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let answer = String(repeating: Self.summarySentence, count: Self.underSpanBudgetAnswerRepeats)
        let outcome = try await Self.foldOutcome(folding: turns, with: stage, prompt: .default, answering: [answer])

        let assembled = try #require(outcome.prompts.first)
        let condensed = try Self.condensedContent(of: assembled)
        let statedBytes = Self.expectedStatedBudgetBytes(
            condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens)
        // Sanity: this span's ask really is above the old quarter-of-content
        // allowance, so the invariant is doing work here.
        let quarterOfContent = Int((Double(Summarization.estimatedTokens(of: condensed)) * stage.summaryTokenRatio).rounded(.up))
        let statedTokens = Int((Double(statedBytes) / Compactor.charsPerTokenEstimate).rounded(.up))
        #expect(statedTokens > quarterOfContent)

        // The answer room the ceiling leaves after the reasoning headroom
        // covers the stated ask.
        let ceiling = try #require(outcome.ceilings.first)
        #expect(Summarization.characters(forEstimatedTokens: ceiling - stage.reasoningTokenHeadroom) >= statedBytes)
    }

    @Test("an answer that fits the span byte budget is stored word for word, however far over the compression target it is")
    func anAnswerInsideTheSpanBudgetIsStoredUnchanged() async throws {
        // The invariant a fold needs is "the boundary entry is smaller than
        // the span it replaces" — `Compactor.compact`'s did-not-shrink guard.
        // The old ratio cut rejected answers that invariant accepts: the
        // 2-seed Qwen probe of 2026-08-20 (task ^xx02yn6) measured both raw
        // answers carrying the planted fact verbatim, and the cut storing the
        // `1. Intent` line alone. The bound is the span now, so an answer the
        // guard would accept is stored exactly as the model wrote it.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.largeSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let answer = String(repeating: Self.summarySentence, count: Self.underSpanBudgetAnswerRepeats)
        let outcome = try await Self.foldOutcome(folding: turns, with: stage, prompt: .default, answering: [answer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        #expect(answer.utf8.count <= budget)  // sanity: the answer fits the span budget
        // Sanity: the answer overruns a quarter of the call's content — the
        // old compression-ratio bound — so the old ratio cut would have fired
        // here.
        let condensed = try Self.condensedContent(of: try #require(outcome.prompts.first))
        let quarterOfContent = Int(
            (Double(Summarization.estimatedTokens(of: condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(Summarization.estimatedTokens(of: answer) > quarterOfContent)

        #expect(outcome.prompts.count == 1)  // no condense pass for an answer that fits
        let folded = try #require(outcome.folded)
        #expect(folded.summary == answer)
        #expect(folded.summaryCut == false)
    }

    @Test("an answer over the span byte budget gets one condense call, and a condensed answer that fits is stored with no cut")
    func anOversizedAnswerIsCondensedOnceBeforeAnyCut() async throws {
        // Recovery before destruction (task ^xx02yn6): the model is asked to
        // condense its own summary once, with the tighter budget stated, and
        // an answer that then fits is stored whole — the cut never runs.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let condensedAnswer = "The service reads its configuration from environment variables."
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [oversized, condensedAnswer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        #expect(oversized.utf8.count > budget)  // sanity: the first answer overruns
        #expect(condensedAnswer.utf8.count <= budget)  // sanity: the condensed answer fits

        #expect(outcome.prompts.count == 2)
        let condensePrompt = outcome.prompts[1]
        #expect(condensePrompt.contains(oversized))
        #expect(condensePrompt.contains("Rewrite it"))
        #expect(condensePrompt.contains("about \(Self.expectedBudgetWords(forBytes: budget)) words"))

        let folded = try #require(outcome.folded)
        #expect(folded.summary == condensedAnswer)
        #expect(folded.summaryCut == false)
    }

    @Test("when the condense pass still overruns, the last-resort cut fires on a sentence boundary and the fold records the cut")
    func aStillOversizedCondenseAnswerIsCutAndTheCutIsRecorded() async throws {
        // The cut is the last resort, and it is recorded when it fires — so a
        // report can say which folds lost text by position rather than by the
        // model's own choice.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let stillOversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats - 2)
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [oversized, stillOversized])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        #expect(stillOversized.utf8.count > budget)  // sanity: the condense pass still overruns

        #expect(outcome.prompts.count == 2)  // exactly one condense pass, never a second
        let folded = try #require(outcome.folded)
        #expect(folded.summaryCut)
        #expect(folded.summary.utf8.count <= budget)
        // The cut takes the smaller candidate — the condensed answer — and
        // lands on a sentence boundary, because a summary is what a resumed
        // session reads.
        #expect(stillOversized.hasPrefix(folded.summary))
        #expect(folded.summary.hasSuffix("."))
    }

    @Test(
        "the last-resort cut of a sectioned answer falls on a section boundary, so a stored summary never ends inside an unfinished section"
    )
    func theLastResortCutOfASectionedAnswerFallsOnASectionBoundary() async throws {
        // The defect `^51e9dyq` measured: the default prompt scaffolds eight
        // numbered sections, and a sentence-boundary cut stored a scaffold
        // that stops in the middle of a section. The session model read that
        // truncated scaffold as its context and degenerated on its next turn.
        // A cut at a SECTION boundary stores whole sections only.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.sectionedCutSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let sections = (1...Self.sectionedAnswerSectionCount).map { Self.sectionedAnswerSection(index: $0) }
        let answer = sections.joined(separator: "\n")
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        let kept = sections.prefix(Self.keptSectionCount).joined(separator: "\n")
        let oneSectionMore = sections.prefix(Self.keptSectionCount + 1).joined(separator: "\n")
        // Sanity: the kept sections really fit the budget, and one more really
        // does not, so the expected cut point is observable.
        #expect(kept.utf8.count <= budget)
        #expect(oneSectionMore.utf8.count > budget)

        let folded = try #require(outcome.folded)
        #expect(folded.summary == kept)
        #expect(folded.summaryCut)
    }

    @Test("a sectioned answer whose first section overruns the whole budget falls back to the sentence boundary")
    func anOversizedFirstSectionFallsBackToTheSentenceBoundary() async throws {
        // When not even one whole section fits the budget, a section-aligned
        // cut would store nothing — the `^bgxtdk3` defect. The cut falls back
        // to the sentence boundary inside the first section instead, which is
        // the trade ``Summarization/cut(_:toCharacters:)`` documents.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let firstSection =
            "1. Intent — " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let answer = firstSection + "\n2. Next steps — none."
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        #expect(firstSection.utf8.count > budget)  // sanity: not even one whole section fits

        let folded = try #require(outcome.folded)
        #expect(folded.summaryCut)
        #expect(answer.hasPrefix(folded.summary))
        #expect(folded.summary.hasSuffix("."))
        #expect(folded.summary.utf8.count <= budget)
    }

    @Test("a short answer is stored word for word, with no condense pass and no cut")
    func aShortAnswerIsStoredUnchanged() async throws {
        // The bound is a bound, not a rewrite. A summarizer whose answer fits
        // the span budget gets it stored exactly as it wrote it.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let answer = "The batch size is a setting rather than a constant."
        let outcome = try await Self.foldOutcome(
            folding: try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput),
            with: stage,
            prompt: .default,
            answering: [answer]
        )

        #expect(outcome.prompts.count == 1)
        let folded = try #require(outcome.folded)
        #expect(folded.summary == answer)
        #expect(folded.summaryCut == false)
    }

    @Test("an answer with no sentence boundary is cut at a word boundary rather than through a word")
    func aSummaryWithNoSentenceBoundaryIsCutAtAWordBoundary() async throws {
        // A model that answers in fragments, or in one long bullet, still gets
        // a bound — and still gets whole words.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let word = "configuration "
        let wordRepeats = 60
        let answer = String(repeating: word, count: wordRepeats)
        let turns = try TranscriptFixtures.makeTurns(5)
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        let folded = try #require(outcome.folded)
        #expect(folded.summaryCut)
        #expect(folded.summary.utf8.count <= budget)
        #expect(answer.hasPrefix(folded.summary))
        #expect(folded.summary.hasSuffix(word.trimmingCharacters(in: .whitespaces)))
    }

    @Test("an answer the cut finds no boundary in still carries text, so a fold never stores nothing")
    func theCutNeverStoresAnEmptySummary() async throws {
        // An empty summary erases the span it replaced — the defect `^bgxtdk3`
        // measured on 19 of 19 gated seeds. A bound that could produce one
        // would trade that defect back in, so the last fallback of the cut is
        // the whole budget rather than a boundary that is not there.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let unbrokenRunLength = 900
        let answer = String(repeating: "x", count: unbrokenRunLength)
        let turns = try TranscriptFixtures.makeTurns(5)
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(1)))
        let folded = try #require(outcome.folded)
        #expect(!folded.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(folded.summary.utf8.count <= budget)
    }

    @Test("a chunked fold hands each map call's answer to the reduce round whole — no per-call cut")
    func mapCallAnswersReachTheReduceRoundUncut() async throws {
        // The per-call ratio cut is the arithmetic task ^xx02yn6 removed: it
        // trimmed answers by position that the shrink invariant would accept.
        // An intermediate answer never enters the transcript, so the only
        // bound it needs is the generation ceiling it was written under; the
        // final summary is bounded against the span, once, where the
        // invariant lives.
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let oneTurnTokens = Compactor.estimatedTokenCount(of: Transcript(entries: turns[0]))
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)
        let mapAnswerA = "A: " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let mapAnswerB = "B: " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let finalAnswer = "final-combined-summary"
        let outcome = try await Self.foldOutcome(
            folding: turns, with: stage, prompt: .default, answering: [mapAnswerA, mapAnswerB, finalAnswer])

        // Sanity: the final answer fits the span budget, so no condense pass
        // follows the reduce round and the call count stays observable.
        let budget = Self.expectedSummaryByteBudget(foldingOld: Array(turns.prefix(2)))
        #expect(finalAnswer.utf8.count <= budget)

        // 2 map calls + 1 reduce call, and the reduce call reads both map
        // answers WHOLE — the old per-call cut would have trimmed each one
        // down to a share of its own chunk first.
        #expect(outcome.prompts.count == 3)
        let reducePrompt = outcome.prompts[2]
        #expect(reducePrompt.contains(mapAnswerA))
        #expect(reducePrompt.contains(mapAnswerB))
        #expect(try #require(outcome.folded).summary == finalAnswer)
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
            repeating: "y", count: Summarization.characters(forEstimatedTokens: oversizedSummaryTokens))
        let responses = (1...3).map { _ in oversizedResponse } + ["flat-fallback-summary"]
        let summarizer = ScriptedSummarizer(responses: responses)
        // A ratio above one half, because `summarizeOnce` now cuts every map
        // call's answer down to its own allowance. A chunk of `maxChunkTokens`
        // therefore yields a summary of `ratio * maxChunkTokens`, and
        // `chunkStrings` can pair two of those under `maxChunkTokens` for any
        // ratio at or below a half — so at the default 0.25 a fold cannot reach
        // the no-progress fallback through a chunk this size at all. (It still
        // reaches it through a chunk SMALLER than
        // `Summarization.minimumSummaryTokens`, where the allowance floor
        // exceeds the chunk ceiling — the shape
        // `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible` folds.)
        // The ratio is what this test needs to be doing the work, since the
        // bound it asserts is the cap rather than the floor.
        let pairingDefeatingRatio = 0.6
        let stage = Summarization(
            keepRecentTurns: 4, maxChunkTokens: maxChunkTokens, summaryTokenRatio: pairingDefeatingRatio)

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
        try makeSizedFoldFixture(phrase: "large content", repeatsPerText: foldFixtureRepeatsPerTurn)
    }

    /// The one construction every sized fold fixture here shares: a header,
    /// ``foldFixtureTurnCount`` turns whose three text fields each repeat
    /// `"<phrase> turn-<index> "` `repeatsPerText` times, and the usual
    /// fold-forcing budget. The phrase names the fixture in a summarizer's
    /// assembled prompt, and the repeat count sets the span's size.
    ///
    /// - Parameters:
    ///   - phrase: The text each turn's fields open with.
    ///   - repeatsPerText: How many times each field repeats its phrase.
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to fold it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeSizedFoldFixture(phrase: String, repeatsPerText: Int) throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...foldFixtureTurnCount).map { index -> [Transcript.Entry] in
            let text = String(repeating: "\(phrase) turn-\(index) ", count: repeatsPerText)
            return try TranscriptFixtures.makeTurn(
                index: index, promptText: text, toolOutputText: text, responseText: text)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })
        return (turns, transcript, makeFoldForcingBudget(for: transcript))
    }

    /// The small-span fixture the last-resort cut is exercised over through
    /// `Compactor.compact`: a header, six SMALL turns, and the same budget
    /// every fixture here uses.
    ///
    /// Small on purpose: the span's byte budget sits far under every scripted
    /// answer, and under the ``Summarization/minimumSummaryTokens`` floor's
    /// own size, so a fold of this span can only shrink through the recovery
    /// ladder — and the ladder's last step, the cut, is what the tests over
    /// this fixture observe.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to fold it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeSmallSpanFoldFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        let turns = try TranscriptFixtures.makeTurns(foldFixtureTurnCount)
        let transcript = Transcript(entries: [TranscriptFixtures.makeInstructions()] + turns.flatMap { $0 })
        return (turns, transcript, makeFoldForcingBudget(for: transcript))
    }

    /// The budget that forces `transcript` all the way through to
    /// ``Summarization``: a target at half of what ``ToolOutputElision`` and
    /// ``TurnTruncation`` reach between them, which neither of them can land
    /// under.
    ///
    /// - Parameter transcript: The transcript the target is measured against.
    /// - Returns: The budget to fold it with.
    private static func makeFoldForcingBudget(for transcript: Transcript) -> TokenBudget {
        let afterBoth = Compactor.estimatedTokenCount(of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        let targetShareOfDeterministicFloor = 2
        return TokenBudget(
            limit: foldFixtureBudgetLimit,
            trigger: foldFixtureTrigger,
            target: Double(afterBoth / targetShareOfDeterministicFloor) / Double(foldFixtureBudgetLimit)
        )
    }

    // MARK: - Parked-runs fold fixtures (task ^64f3hnv)

    /// How many runs ``makeParkedRuns()`` parks — the shape task ^64f3hnv
    /// measured: ten runs with an eight-byte op and no progress render 973
    /// bytes, a cost the fold pays per run rather than per span byte.
    private static let parkedRunCount = 10

    /// How many times each text field of a ``makeParkedRunsFoldFixture()``
    /// turn repeats its phrase — sized so the folded span comes to roughly 580
    /// estimated tokens: large enough that the retention bound sits under the
    /// span, and small enough that the ten parked runs' rendering eats the
    /// whole margin between the two.
    private static let parkedRunsFixtureRepeatsPerText = 20

    /// How many times each text field of an
    /// ``makeOverwhelmedSpanFoldFixture()`` turn repeats its phrase — sized so
    /// the span's content bytes stay UNDER the parked runs' rendering plus the
    /// shrink margin, which drives the span byte budget to zero or below: the
    /// geometry where no summary of any length can make the fold shrink, and
    /// only the did-not-shrink guard can answer.
    private static let overwhelmedSpanRepeatsPerText = 8

    /// How many times the parked-runs tests' scripted answer repeats its
    /// phrase — far past every retention bound in these fixtures, so the cut
    /// always runs.
    private static let parkedRunsAnswerRepeats = 200

    /// Parked-run summaries in the shape task ^64f3hnv measured:
    /// ``parkedRunCount`` runs, each with a 26-character completion token, an
    /// eight-byte op, and no progress reported yet.
    ///
    /// - Returns: The parked runs, in park order.
    private static func makeParkedRuns() -> [CompactionSegment.PendingRunSummary] {
        (1...parkedRunCount).map { index in
            CompactionSegment.PendingRunSummary(
                completionToken: String(format: "01ARZ3NDEKTSV4RRFFQ69G5F%02d", index),
                op: "run tool",
                latestProgressDetail: nil
            )
        }
    }

    /// The fixture `aFoldWithParkedRunsOverAModestSpanIsStillApplied` folds: a
    /// header, six MODEST turns, and the usual fold-forcing budget. Modest is
    /// the point — the span is small enough that the parked runs' rendering
    /// spends the whole retention margin, and large enough that a summary cut
    /// down for that rendering still shrinks the transcript.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to fold it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeParkedRunsFoldFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        try makeSizedFoldFixture(phrase: "modest span", repeatsPerText: parkedRunsFixtureRepeatsPerText)
    }

    /// The fixture whose span the parked runs' rendering overwhelms: small
    /// enough that the rendering alone reaches the retention bound, and still
    /// larger than the rendering — so a cut that (wrongly) emptied the summary
    /// would make the fold shrink and be applied carrying no text at all.
    ///
    /// - Returns: The turns in order, the transcript over them, and the budget
    ///   to fold it against.
    /// - Throws: Whatever the fixture construction throws.
    private static func makeOverwhelmedSpanFoldFixture() throws -> (
        turns: [[Transcript.Entry]], transcript: Transcript, budget: TokenBudget
    ) {
        try makeSizedFoldFixture(phrase: "tiny span", repeatsPerText: overwhelmedSpanRepeatsPerText)
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
        "a fold of a span smaller than every answer is still applied: the last-resort cut bounds the summary under the span, and the result records the cut"
    )
    func compactReportsTheLastResortCut() async throws {
        // The trim fires only when the fold would otherwise fail to shrink,
        // and the report records when it fires (task ^xx02yn6). A span this
        // small earns a byte budget far under every candidate answer, so the
        // recovery ladder runs to its last step and `CompactionResult` says
        // so.
        let (turns, transcript, budget) = try Self.makeSmallSpanFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let oldTurns = Array(turns.prefix(Self.foldFixtureTurnCount - Summarization().keepRecentTurns))
        let summarizer = OversizedSummarizer(summary: String(repeating: "verbose summary ", count: tokensBefore))
        let spanBudget = Self.expectedSummaryByteBudget(foldingOld: oldTurns)
        #expect(summarizer.summary.utf8.count > spanBudget)  // sanity: every answer overruns

        let (_, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        #expect(result.stagesApplied.last == Summarization.stageName)
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)
        let summary = try #require(result.summary)
        #expect(summarizer.summary.hasPrefix(summary))
        #expect(summary.utf8.count <= spanBudget)
    }

    @Test("a result that recorded the last-resort cut keeps it through the summarizer-model naming copy")
    func withSummarizerModelKeepsTheRecordedCut() {
        let result = CompactionResult(
            summary: "cut summary", summaryCut: true, tokensBefore: 100, tokensAfter: 50,
            stagesApplied: [Summarization.stageName])
        #expect(result.withSummarizerModel("mlx-community/example").summaryCut)
    }

    @Test(
        "a fold whose summarizer ignored every ceiling is applied rather than discarded, because the recovery ladder brought the summary under the span"
    )
    func aFoldWhoseSummaryOverranItsAllowanceIsStillApplied() async throws {
        // This is what enforcing the bound in code buys. `^fm5ddk9` measured 7
        // of 7 gated seeds answering 1.30x to 2.07x the size of the span they
        // were condensing, so `Compactor` discarded 7 of 7 folds and the eval
        // measured nothing about compaction at all. An answer of that shape now
        // folds, and the guard below it is untouched — it stays the backstop
        // for the fold no cut can save.
        let (_, transcript, budget) = try Self.makeModelAssistedFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let summarizer = OversizedSummarizer(summary: String(repeating: "verbose summary ", count: tokensBefore))
        // sanity: the raw answer really would have grown the transcript
        #expect(Summarization.estimatedTokens(of: summarizer.summary) > tokensBefore)

        let (_, result) = try await Compactor.compact(transcript, budget: budget, summarizer: summarizer)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)
        let summary = try #require(result.summary)
        #expect(summarizer.summary.hasPrefix(summary))
    }

    @Test(
        "a fold over a modest span with parked runs is applied: the cut leaves room for the pending-runs rendering the boundary entry carries"
    )
    func aFoldWithParkedRunsOverAModestSpanIsStillApplied() async throws {
        // The shape task ^64f3hnv measured. The per-call cut bounds the summary
        // TEXT, the did-not-shrink guard measures the whole replacement ENTRY,
        // and the boundary entry carries the pending-runs rendering as a second
        // .text segment. On a modest span the rendering alone used to spend the
        // retention margin, so the fold was discarded whatever the summary said
        // — and a session that parks background runs is the case the rendering
        // exists for. The cut now charges the rendering against the bound.
        let (turns, transcript, budget) = try Self.makeParkedRunsFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let pendingRuns = Self.makeParkedRuns()
        let rendering = CompactionSegment.renderedPendingRuns(pendingRuns)
        let renderingTokens = Summarization.estimatedTokens(of: rendering)
        let spanEntries = turns.prefix(Self.foldFixtureTurnCount - Summarization().keepRecentTurns).flatMap { $0 }
        let spanTokens = Compactor.estimatedTokenCount(of: Transcript(entries: spanEntries))

        let answer = String(repeating: "verbose summary ", count: Self.parkedRunsAnswerRepeats)
        let summarizer = ScriptedSummarizer(responses: [answer, answer])
        let (_, result) = try await Compactor.compact(
            transcript, budget: budget, summarizer: summarizer, pendingRuns: pendingRuns)

        // The scenario really is the defect's shape, in the guard's own
        // units: the rendering leaves room under the span byte budget, and
        // every candidate answer overruns what is left, so only the recovery
        // ladder's cut can save the fold.
        let spanBytes = Self.spanContentBytes(of: [spanEntries])
        let spanBudget = Self.expectedSummaryByteBudget(
            foldingOld: [spanEntries], renderingBytes: rendering.utf8.count)
        #expect(spanBudget > 0)
        #expect(answer.utf8.count > spanBudget)
        #expect(renderingTokens < spanTokens)

        // Applied, not discarded: the whole entry stays under the span.
        #expect(result.stagesApplied.last == Summarization.stageName)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter < tokensBefore)
        #expect(result.summaryCut)

        // What the fold stored is a prefix of the answer, and the stored
        // summary plus the rendering stay under the span.
        let summary = try #require(result.summary)
        #expect(answer.hasPrefix(summary))
        #expect(summary.utf8.count + rendering.utf8.count < spanBytes)

        // Control: the same fold with no parked runs is applied too, so the
        // pending-runs rendering is the one variable in this scenario.
        let controlSummarizer = ScriptedSummarizer(responses: [answer, answer])
        let (_, control) = try await Compactor.compact(transcript, budget: budget, summarizer: controlSummarizer)
        #expect(control.stagesApplied.last == Summarization.stageName)
        #expect(control.tokensAfter < tokensBefore)
    }

    @Test(
        "a fold whose parked runs' rendering alone spends the span byte budget is discarded whole — never applied with an emptied summary"
    )
    func aFoldWhosePendingRunsRenderingAloneReachesTheBoundIsDiscarded() async throws {
        // Below this bound no summary of any length can pay for the rendering,
        // so the safe answer is the guard's: discard the fold and return the
        // original transcript. The dangerous wrong answer is a cut that empties
        // the summary to make the arithmetic work — the rendering is smaller
        // than the span, so an emptied entry WOULD shrink the transcript, and
        // the fold would be applied carrying no summary text at all.
        let (turns, transcript, budget) = try Self.makeOverwhelmedSpanFoldFixture()
        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let pendingRuns = Self.makeParkedRuns()
        let rendering = CompactionSegment.renderedPendingRuns(pendingRuns)
        let renderingTokens = Summarization.estimatedTokens(of: rendering)
        let spanEntries = turns.prefix(Self.foldFixtureTurnCount - Summarization().keepRecentTurns).flatMap { $0 }
        let spanTokens = Compactor.estimatedTokenCount(of: Transcript(entries: spanEntries))

        let answer = String(repeating: "verbose summary ", count: Self.parkedRunsAnswerRepeats)
        let summarizer = ScriptedSummarizer(responses: [answer])
        let (resultTranscript, result) = try await Compactor.compact(
            transcript, budget: budget, summarizer: summarizer, pendingRuns: pendingRuns)

        // The geometry: the rendering alone drives the span byte budget to
        // zero or below, so no summary of any length can make the fold
        // shrink, and no condense pass is worth a generation.
        let spanBudget = Self.expectedSummaryByteBudget(
            foldingOld: [spanEntries], renderingBytes: rendering.utf8.count)
        #expect(spanBudget <= 0)
        #expect(renderingTokens > 0)
        #expect(spanTokens > 0)

        // One summarizer call only: a budget at or under zero earns no
        // condense pass, because no rewrite of any length could fit it.
        #expect(summarizer.receivedPrompts.count == 1)

        // Discarded whole, exactly like every other fold that cannot shrink.
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
