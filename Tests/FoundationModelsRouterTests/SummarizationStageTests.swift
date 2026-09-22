import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The counter every size in this file is measured with: one token per
/// `Character`. A fixture "of N tokens" is a string of N characters, and a
/// transcript counts the characters of the content the model reads.
private let counter = CharacterTokenCounter()

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
///
/// The suite is one type in two files. `SummarizationStageCompactorTests.swift`
/// holds the reasoning-headroom, no-op, failure and `Compactor.compact` tests.
/// Each file stays under the size the review engine can read in one prompt.
/// The helpers that file uses are internal, not private, for that reason.
@Suite("Summarization stage: map-reduce, prompt assembly, CompactionSegment contents, and CompactionPrompt.default")
struct SummarizationStageTests {
    // MARK: - Scripted summarizer

    /// A ``CompactionSummarizer`` fully controlled by the test: never calls a
    /// real model, records every assembled prompt it receives (in call
    /// order), and returns canned responses from `responses`, cycling a
    /// final placeholder if more calls happen than responses were supplied.
    ///
    /// The class is `Sendable` because `responses` is an immutable
    /// `Sendable` value, and the calls it records are in a `Mutex`.
    final class ScriptedSummarizer: CompactionSummarizer, Sendable {
        /// What the summarizer received, one element per call, in call order.
        private struct Received {
            /// The assembled prompt of each call.
            var prompts: [String] = []

            /// The output ceiling of each call.
            var maxTokens: [Int] = []
        }

        /// The calls received so far.
        private let received = Mutex(Received())

        /// The canned answers, one per call, in call order.
        private let responses: [String]

        /// The assembled prompt of each call, in call order.
        var receivedPrompts: [String] {
            received.withLock { $0.prompts }
        }

        /// The output ceiling each call was given, in call order — the bound a
        /// real summarizer would generate under.
        var receivedMaxTokens: [Int] {
            received.withLock { $0.maxTokens }
        }

        /// Creates the summarizer.
        ///
        /// - Parameter responses: The canned answers, one per call, in call order.
        init(responses: [String]) {
            self.responses = responses
        }

        func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
            let index = received.withLock { state in
                state.prompts.append(prompt)
                state.maxTokens.append(maxTokens)
                return state.prompts.count - 1
            }
            return index < responses.count ? responses[index] : "unscripted-response-\(index)"
        }
    }

    /// A ``CompactionSummarizer`` that always throws, for asserting that a
    /// summarizer failure propagates rather than being silently swallowed.
    struct ThrowingSummarizer: CompactionSummarizer {
        struct Failure: Error {}
        func summarize(_ prompt: String, maxTokens: Int) async throws -> String { throw Failure() }
    }

    /// A ``CompactionSummarizer`` whose answer is far larger than anything it
    /// could be asked to condense — a model that ignores the ceiling it was
    /// given, which is the one thing no output bound can prevent.
    struct OversizedSummarizer: CompactionSummarizer {
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
    static func expectedCeiling(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int,
        headroom: Int
    ) -> Int {
        expectedSummaryAllowance(condensing: content, ratio: ratio, maxChunkTokens: maxChunkTokens) + headroom
    }

    /// The part of that ceiling the summary text itself may occupy: the
    /// STATED budget, in tokens, never below
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
    static func expectedSummaryAllowance(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int
    ) -> Int {
        max(
            Summarization.minimumSummaryTokens,
            expectedStatedBudgetTokens(condensing: content, ratio: ratio, maxChunkTokens: maxChunkTokens))
    }

    /// The tokens the stated budget should name for a call condensing
    /// `content`: the stated share of the content's tokens, capped at what a
    /// full `maxChunkTokens` of content earns at `ratio` so the final summary
    /// of a conversation of any length stays bounded. Restated here rather
    /// than read off the stage, so these tests pin the arithmetic instead of
    /// comparing it against itself.
    ///
    /// - Parameters:
    ///   - content: The content the call was asked to condense.
    ///   - ratio: The stage's ``Summarization/summaryTokenRatio``.
    ///   - maxChunkTokens: The stage's ``Summarization/maxChunkTokens``.
    /// - Returns: The expected stated budget, in tokens.
    private static func expectedStatedBudgetTokens(
        condensing content: String,
        ratio: Double,
        maxChunkTokens: Int
    ) -> Int {
        let statedShare = 0.75
        let capTokens = max(Summarization.minimumSummaryTokens, Int((Double(maxChunkTokens) * ratio).rounded(.up)))
        return min(Int(Double(counter.count(content)) * statedShare), capTokens)
    }

    /// The UTF-8 bytes the first `tokens` tokens of `text` occupy. The word
    /// count the stage states to the model comes from these bytes. They are
    /// read from the text itself, cut by the counter, never from a
    /// conversion factor.
    ///
    /// - Parameters:
    ///   - tokens: The number of tokens to measure.
    ///   - text: The text the tokens are read from.
    /// - Returns: The byte size of that prefix.
    private static func bytes(ofFirst tokens: Int, in text: String) -> Int {
        counter.prefix(of: text, tokens: tokens).utf8.count
    }

    /// The token budget the compaction's FINAL summary must fit for the
    /// boundary entry to shrink the transcript (task ^xx02yn6): the compacted
    /// span's own tokens, minus the shrink margin of one token, minus the
    /// pending-runs rendering the boundary entry carries beside the summary.
    /// The span is counted the way the stage counts it, and the budget is the
    /// stage's own function of that count.
    ///
    /// - Parameters:
    ///   - oldTurns: The compacted span's turns, each as its own entries.
    ///   - renderingTokens: The pending-runs rendering's token count — `0`,
    ///     the default, when the compaction tracks no runs.
    /// - Returns: The expected budget, in tokens.
    /// - Throws: What the counter throws.
    static func expectedSummaryTokenBudget(
        compactingOld oldTurns: [[Transcript.Entry]],
        renderingTokens: Int = 0
    ) throws -> Int {
        Summarization.summaryTokenBudget(
            forSpanTokens: try spanTokens(of: oldTurns), pendingRunsRenderingTokens: renderingTokens)
    }

    /// The tokens of a compacted span's turns: the count of the span's
    /// entries as one transcript. The stage subtracts the protected entries
    /// it keeps; no test here protects a tool output, so nothing is
    /// subtracted.
    ///
    /// - Parameter oldTurns: The compacted span's turns, each as its own entries.
    /// - Returns: The span's size, in tokens.
    /// - Throws: What the counter throws.
    private static func spanTokens(of oldTurns: [[Transcript.Entry]]) throws -> Int {
        try counter.count(Transcript(entries: oldTurns.flatMap { $0 }))
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

    /// Compacts `turns` with `stage` and `prompt`, and returns the assembled
    /// prompt of every summarizer call the compaction made, in call order.
    ///
    /// The turns come in rather than being built here because a caller sizing
    /// `stage.maxChunkTokens` against one turn has to measure that turn before
    /// the compaction runs.
    ///
    /// - Parameters:
    ///   - turns: The turns to compact, each as its own entries.
    ///   - stage: The stage to compact with.
    ///   - prompt: The compaction prompt to compact with.
    ///   - responses: What the scripted summarizer answers, one per call.
    /// - Returns: The assembled prompts, in call order.
    /// - Throws: Whatever the compaction throws.
    private static func assembledPrompts(
        compacting turns: [[Transcript.Entry]],
        with stage: Summarization,
        prompt: CompactionPrompt,
        answering responses: [String]
    ) async throws -> [String] {
        try await compactionOutcome(compacting: turns, with: stage, prompt: prompt, answering: responses).prompts
    }

    /// Compacts `turns` with `stage` and `prompt`, and returns both what the compaction
    /// stored and the assembled prompt of every summarizer call it made.
    ///
    /// What a compaction STORES is not what its summarizer ANSWERED — the stage cuts
    /// an answer down to the share of its content that call may retain — so a test about that
    /// bound has to read the compaction's own result rather than the scripted answer
    /// it started from.
    ///
    /// - Parameters:
    ///   - turns: The turns to compact, each as its own entries.
    ///   - stage: The stage to compact with.
    ///   - prompt: The compaction prompt to compact with.
    ///   - responses: What the scripted summarizer answers, one per call.
    /// - Returns: What the compaction stored, the assembled prompts in call order,
    ///   and the ceiling each call was given.
    /// - Throws: Whatever the compaction throws.
    private static func compactionOutcome(
        compacting turns: [[Transcript.Entry]],
        with stage: Summarization,
        prompt: CompactionPrompt,
        answering responses: [String]
    ) async throws -> (compacted: Summarization.Compacted?, prompts: [String], ceilings: [Int]) {
        let transcript = Transcript(entries: [TranscriptFixtures.makeInstructions()] + turns.flatMap { $0 })
        let summarizer = ScriptedSummarizer(responses: responses)
        let compacted = try await stage.apply(
            transcript,
            prompt: prompt,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        return (compacted, summarizer.receivedPrompts, summarizer.receivedMaxTokens)
    }

    /// The content a summarizer call was asked to condense, recovered from the
    /// assembled prompt it received — the compaction instructions, then the
    /// separator, then the content (see `Summarization.summarizeOnce`).
    ///
    /// - Parameter prompt: The assembled prompt the call received.
    /// - Returns: The content part alone.
    static func condensedContent(of prompt: String) throws -> String {
        try #require(prompt.components(separatedBy: "\n\n---\n\n").last)
    }

    /// A ``Summarization/maxChunkTokens`` wide enough to hold any fixture span
    /// here in a single summarizer call — the non-default setting a test uses
    /// to prove chunking read the knob it was given.
    static let wholeSpanChunkTokens = 1_000_000

    // MARK: - CompactionPrompt.default matches compaction_plan.md §2 verbatim

    @Test("CompactionPrompt.default's name and text match compaction_plan.md §2 verbatim")
    func defaultPromptMatchesPlanText() {
        let prompt = CompactionPrompt.default
        #expect(prompt.name == "router-default-v4")

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

    @Test("CompactionPrompt.default gives a bare stated fact its own section, so a compaction cannot record that a fact was stated without stating what it was")
    func defaultPromptKeepsBareStatedFacts() {
        // Pins the defect the gated eval measured on the `printer-and-supply-closet`
        // fixture, one of the seventeen task ^k0d30s4 deleted with the
        // whole-dataset tier: the summary read "1. Intent — Inform the assistant about the
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

    @Test(
        "CompactionPrompt.default states no fact of its own, so a model cannot copy an example out of the instructions into the summary"
    )
    func defaultPromptQuotesNoExampleFact() {
        // Task ^49dy082 measured the defect against the real 1B model. The
        // instructions illustrated the verbatim-value demand with a quoted
        // fact, and the model wrote that fact — a value the conversation never
        // stated — sixty times in place of a summary of the span. The compaction
        // stored it, so the span's every real fact was lost.
        let text = CompactionPrompt.default.text
        // The instructions quote nothing, so they carry nothing shaped like a
        // fact of the conversation. Each rule states itself in the abstract.
        #expect(text.contains("\"") == false)
        // The rule is stated outright as well, for a model that reads an
        // instruction as content anyway.
        #expect(text.contains("never copy a phrase out of them"))
        #expect(text.contains("never write a line you have already written"))
    }

    // MARK: - Segment contents: text segment + fully-populated CompactionSegment

    @Test("the synthesized summary entry carries the text segment and a fully-populated CompactionSegment")
    func summaryEntryCarriesFullyPopulatedSegment() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "old result \($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })
        let tokensBefore = try counter.count(transcript)

        let summarizer = ScriptedSummarizer(responses: ["the compacted turns discussed a search query and its result"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: tokensBefore,
            priorStagesApplied: ["ToolOutputElision", "TurnTruncation"],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

        #expect(unwrapped.summary == "the compacted turns discussed a search query and its result")

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
        #expect(segment.content.compactedEntryIds == turns[0].map(\.id) + turns[1].map(\.id))
        #expect(segment.content.liveWindowEntryIds.first == instructions.id)
        #expect(segment.content.liveWindowEntryIds.contains(response.id))
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }
        #expect(segment.content.liveWindowEntryIds.suffix(expectedRecentTail.count) == expectedRecentTail.map(\.id))
        #expect(segment.content.tokensBefore == tokensBefore)
        // tokensAfter is measured against a provisional build of the final
        // transcript (see Summarization.apply's own doc comment on the
        // two-pass build). The counter reads the text the model reads, and
        // the CompactionSegment beside it is not that text, so the number the
        // segment records is the count of the final transcript itself.
        let finalCount = try counter.count(unwrapped.transcript)
        #expect(segment.content.tokensAfter == finalCount)
        #expect(segment.content.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(segment.content.promptName == "router-default-v4")

        // The recency window itself survives byte-identical.
        #expect(Array(entries.suffix(expectedRecentTail.count)) == expectedRecentTail)
    }

    // MARK: - Prompt assembly: default and custom prompt text sent verbatim

    @Test("the default prompt's text is sent to the summarizer verbatim, alongside the rendered compacted span")
    func defaultPromptAssembledVerbatim() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...5).map { try TranscriptFixtures.makeTurn(index: $0, promptText: "distinctive-question-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
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

        let compacted = try await stage.apply(
            transcript,
            prompt: customPrompt,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

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

    // MARK: - Segment flattening: the text a compaction reads out of an entry

    @Test("flattening an entry's segments joins every text segment in order with a newline and drops the segments that carry no text")
    func flatteningJoinsTextSegmentsAndDropsTheRest() throws {
        // `Summarization.text(of:)` is what turns an entry into the line a
        // summarizer reads, and the compaction eval dataset reads its seed
        // transcripts through the same function so it measures the text a compaction
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

    /// The divisor that sizes one map response of the tree-reduce test
    /// against `maxChunkTokens`: a sixth of it, plus the response's own
    /// prefix. Three responses of that size fit one reduce group, and six do
    /// not, so the reduce step groups them in exactly one round.
    private static let mapResponseShareOfChunk = 6

    /// How many times `maxChunkTokens` an oversized map response of the
    /// flat-fallback tests holds: twice, so no two responses fit one reduce
    /// group and the reduce step can make no grouping progress.
    private static let oversizedResponseChunkMultiple = 2

    @Test("a compacted span exceeding maxChunkTokens is split into multiple chunks, each summarized, then the chunk summaries are re-summarized into one final summary")
    func longSpanMapReducesAcrossChunks() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // Old turns are 1 and 2 (turns 3...6 are the keepRecentTurns: 4 window).
        // A maxChunkTokens equal to one old turn's own counted size forces
        // each old turn into its own chunk: 2 chunks, not 1.
        let oneTurnTokens = try counter.count(Transcript(entries: turns[0]))

        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", "final-combined-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

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

        let maxChunkTokens = try counter.count(Transcript(entries: turns[0]))

        // Each map response holds a named share of maxChunkTokens: small
        // enough that several fit in one reduce group, and large enough that
        // the 6 of them combined exceed maxChunkTokens, so the reduce step
        // groups rather than flat-joins everything into a single over-budget
        // call. The "map-N-" prefix adds to each item's size, so the exact
        // grouping is derived below through `Summarization.chunkStrings`
        // itself (the same function production code uses) rather than
        // hand-computed.
        let mapResponseTokens = maxChunkTokens / Self.mapResponseShareOfChunk
        let mapResponses = (1...6).map { "map-\($0)-" + String(repeating: "x", count: mapResponseTokens) }
        let predictedGroups = Summarization.chunkStrings(mapResponses, maxTokens: maxChunkTokens, counter: counter)
        #expect(predictedGroups.count > 1)  // sanity: this scenario truly forces multiple groups

        // Sanity: the first-round answers fit one call together, so the
        // recursion ends after exactly one more call.
        let firstRoundAnswers = predictedGroups.indices.map { "round1-group-\($0)" }
        #expect(counter.count(firstRoundAnswers.joined(separator: "\n\n")) <= maxChunkTokens)

        let responses =
            mapResponses  // 6 map calls
            + firstRoundAnswers  // one reduce call per predicted group
            + ["final-tree-reduced-summary"]  // 1 final reduce call
        let summarizer = ScriptedSummarizer(responses: responses)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

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

        let maxChunkTokens = try counter.count(Transcript(entries: turns[0]))

        // Each map response is deliberately oversized on its own (twice
        // maxChunkTokens) so the reduce step's chunkStrings groups each one
        // into its own singleton batch — no grouping progress is possible,
        // which must trigger the flat-fallback rather than recursing forever.
        let oversizedResponse = String(repeating: "y", count: maxChunkTokens * Self.oversizedResponseChunkMultiple)
        #expect(counter.count(oversizedResponse) > maxChunkTokens)

        let responses = (1...3).map { _ in oversizedResponse } + ["flat-fallback-summary"]
        let summarizer = ScriptedSummarizer(responses: responses)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

        // 3 map calls + exactly 1 flat-fallback reduce call — proves the
        // no-progress guard terminated immediately rather than recursing.
        #expect(summarizer.receivedPrompts.count == 4)
        #expect(unwrapped.summary == "flat-fallback-summary")
    }

    @Test("a short compacted span within maxChunkTokens needs no chunking: exactly one summarizer call")
    func shortSpanNeedsNoChunking() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let summarizer = ScriptedSummarizer(responses: ["single-call-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        let compacted = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )
        let unwrapped = try #require(compacted)

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
        // ceiling is the whole compaction's.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: 1_000_000)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
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
        // the span it replaces, which is what made a compaction save almost nothing.
        // The bound is on the summary allowance, read back off the ceiling the
        // call was given — the reasoning headroom beside it is never summary
        // text, so it cannot make a summary longer.
        #expect(ceiling - stage.reasoningTokenHeadroom < counter.count(condensed))
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
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        let share = Int((Double(counter.count(condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(share < Summarization.minimumSummaryTokens)  // sanity: this span's share really is below the floor
        #expect(
            summarizer.receivedMaxTokens == [Summarization.minimumSummaryTokens + stage.reasoningTokenHeadroom])
    }

    // MARK: - The final summary is bounded against the span, and the budget is stated to the model

    /// One sentence a scripted summarizer answers with, repeated to build an
    /// answer that overruns the span token budget its compaction earns.
    ///
    /// It ends in a period and a space, so a cut at a sentence boundary has
    /// somewhere to land.
    private static let summarySentence =
        "The service reads its whole configuration from environment variables at startup. "

    /// How many times ``summarySentence`` repeats to make one over-long answer
    /// — far past the span token budget every small fixture span here earns.
    private static let summarySentenceRepeats = 12

    /// The tool-output text that makes a compacted span's token budget larger
    /// than an answer of ``underSpanBudgetAnswerRepeats`` sentences, while
    /// that answer still overruns the compression allowance the call
    /// generated under — the band the old ratio cut took and the span bound
    /// leaves alone (task ^xx02yn6).
    private static let largeSpanToolOutput = String(repeating: summarySentence, count: 40)

    /// How many times ``summarySentence`` repeats to make an answer that sits
    /// ABOVE the generation allowance and BELOW the span token budget a
    /// ``largeSpanToolOutput`` span earns.
    private static let underSpanBudgetAnswerRepeats = 20

    /// The tool-output text that gives a small fixture span a token budget of
    /// a few hundred tokens — wide enough that a short condensed answer fits
    /// it, and narrow enough that a ``summarySentenceRepeats`` answer
    /// overruns it.
    private static let condensableSpanToolOutput = String(repeating: summarySentence, count: 2)

    /// The tool-output text that sizes a span so its token budget keeps some
    /// whole sections of a ``sectionedAnswerSection(index:)`` answer and not
    /// all of them, so the section-aligned cut point is observable.
    private static let sectionedCutSpanToolOutput = String(repeating: summarySentence, count: 6)

    /// One numbered section of a scripted sectioned answer, in the shape the
    /// default prompt's scaffold produces: a flush-left `N. ` header, then
    /// full sentences.
    ///
    /// Every index the tests use is a single digit, so each section holds the
    /// same token count and the section a cut keeps or drops is deterministic.
    ///
    /// - Parameter index: The section's number.
    /// - Returns: The section, one line.
    private static func sectionedAnswerSection(index: Int) -> String {
        "\(index). Topic \(index) — the compaction keeps the facts of kind \(index) here. "
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
            compacting: try TranscriptFixtures.makeTurns(5),
            with: stage,
            prompt: .default,
            answering: ["summary"]
        )

        let assembled = try #require(prompts.first)
        let condensed = try Self.condensedContent(of: assembled)
        // The stated budget is a share of the CONTENT the call condenses —
        // near the span token budget the compaction enforces — never the compression
        // allowance. The instrumented Qwen probes of 2026-08-20 measured why:
        // an allowance-derived 85-word target against an eight-section
        // verbatim-fact demand is unsatisfiable, and the thinking model spent
        // whole 4224- and 8320-token ceilings drafting and word-counting
        // inside `<think>`, answering EMPTY on 2 of 2 seeds both times.
        // The word count comes from the bytes of the first stated tokens of
        // the content itself, never from a conversion factor.
        let statedTokens = Self.expectedStatedBudgetTokens(
            condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens)
        let words = Self.expectedBudgetWords(forBytes: Self.bytes(ofFirst: statedTokens, in: condensed))
        // "about N words ... never count": the same probes captured the model
        // counting its draft word by word against the target, so the line
        // forbids the verification outright as its own rule.
        //
        // The framing line between the budget and the separator is task
        // ^49dy082's: without it a small model summarized these INSTRUCTIONS
        // in place of the conversation, and named a value out of them that the
        // conversation never stated.
        #expect(
            assembled
                == "\(CompactionPrompt.default.text)\n\nSize budget: about \(words) words. "
                + "This is a rough ceiling — never count or verify the length; a near miss is fine."
                + "\n\n\(Summarization.contentFramingDirective)\n\n---\n\n\(condensed)"
        )
        // The framing has to stand where the model reads it as an instruction:
        // ahead of the separator, never inside the content it describes.
        #expect(condensed.contains(Summarization.contentFramingDirective) == false)
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
        let outcome = try await Self.compactionOutcome(compacting: turns, with: stage, prompt: .default, answering: [answer])

        let assembled = try #require(outcome.prompts.first)
        let condensed = try Self.condensedContent(of: assembled)
        let statedTokens = Self.expectedStatedBudgetTokens(
            condensing: condensed, ratio: stage.summaryTokenRatio, maxChunkTokens: stage.maxChunkTokens)
        // Sanity: this span's ask really is above the old quarter-of-content
        // allowance, so the invariant is doing work here.
        let quarterOfContent = Int((Double(counter.count(condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(statedTokens > quarterOfContent)

        // The answer room the ceiling leaves after the reasoning headroom
        // covers the stated ask.
        let ceiling = try #require(outcome.ceilings.first)
        #expect(ceiling - stage.reasoningTokenHeadroom >= statedTokens)
    }

    @Test("an answer that fits the span token budget is stored word for word, however far over the compression target it is")
    func anAnswerInsideTheSpanBudgetIsStoredUnchanged() async throws {
        // The invariant a compaction needs is "the boundary entry is smaller than
        // the span it replaces" — `Compactor.compact`'s did-not-shrink guard.
        // The old ratio cut rejected answers that invariant accepts: the
        // 2-seed Qwen probe of 2026-08-20 (task ^xx02yn6) measured both raw
        // answers carrying the planted fact verbatim, and the cut storing the
        // `1. Intent` line alone. The bound is the span now, so an answer the
        // guard would accept is stored exactly as the model wrote it.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.largeSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let answer = String(repeating: Self.summarySentence, count: Self.underSpanBudgetAnswerRepeats)
        let outcome = try await Self.compactionOutcome(compacting: turns, with: stage, prompt: .default, answering: [answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(answer) <= budget)  // sanity: the answer fits the span budget
        // Sanity: the answer overruns a quarter of the call's content — the
        // old compression-ratio bound — so the old ratio cut would have fired
        // here.
        let condensed = try Self.condensedContent(of: try #require(outcome.prompts.first))
        let quarterOfContent = Int(
            (Double(counter.count(condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(counter.count(answer) > quarterOfContent)

        #expect(outcome.prompts.count == 1)  // no condense pass for an answer that fits
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == answer)
        #expect(compacted.summaryCut == false)
    }

    @Test("an answer over the span token budget gets one condense call, and a condensed answer that fits is stored with no cut")
    func anOversizedAnswerIsCondensedOnceBeforeAnyCut() async throws {
        // Recovery before destruction (task ^xx02yn6): the model is asked to
        // condense its own summary once, with the tighter budget stated, and
        // an answer that then fits is stored whole — the cut never runs.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let condensedAnswer = "The service reads its configuration from environment variables."
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [oversized, condensedAnswer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(oversized) > budget)  // sanity: the first answer overruns
        #expect(counter.count(condensedAnswer) <= budget)  // sanity: the condensed answer fits

        #expect(outcome.prompts.count == 2)
        let condensePrompt = outcome.prompts[1]
        #expect(condensePrompt.contains(oversized))
        #expect(condensePrompt.contains("Rewrite it"))
        // The re-ask states the budget in words, read off the bytes the first
        // `budget` tokens of the oversized answer itself occupy.
        let budgetWords = Self.expectedBudgetWords(forBytes: Self.bytes(ofFirst: budget, in: oversized))
        #expect(condensePrompt.contains("about \(budgetWords) words"))

        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == condensedAnswer)
        #expect(compacted.summaryCut == false)
    }

    @Test("when the condense pass still overruns, the last-resort cut fires on a sentence boundary and the compaction records the cut")
    func aStillOversizedCondenseAnswerIsCutAndTheCutIsRecorded() async throws {
        // The cut is the last resort, and it is recorded when it fires — so a
        // report can say which compactions lost text by position rather than by the
        // model's own choice.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let stillOversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats - 2)
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [oversized, stillOversized])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(stillOversized) > budget)  // sanity: the condense pass still overruns

        #expect(outcome.prompts.count == 2)  // exactly one condense pass, never a second
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summaryCut)
        #expect(counter.count(compacted.summary) <= budget)
        // The cut takes the smaller candidate — the condensed answer — and
        // lands on a sentence boundary, because a summary is what a resumed
        // session reads.
        #expect(stillOversized.hasPrefix(compacted.summary))
        #expect(compacted.summary.hasSuffix("."))
    }

    /// The tool-output text that sizes a span so a compaction under the stage's own
    /// ``Summarization/maxChunkTokens`` gives its condense re-ask MORE room
    /// than its map call had.
    ///
    /// The map call is asked for ``Summarization/statedBudgetShareOfContent``
    /// of its own content, while the condense re-ask is asked for the whole
    /// span token budget, capped at what a full `maxChunkTokens` of content
    /// earns. A span this size makes that cap the binding one, so the two
    /// allowances part company — the shape the real-model compaction of 2026-09-01
    /// measured at a ceiling of 628 against one of 617.
    private static let cappedAllowanceSpanToolOutput = String(repeating: summarySentence, count: 30)

    /// How many times ``summarySentence`` repeats to make an answer that
    /// overruns the token budget a ``cappedAllowanceSpanToolOutput`` span earns.
    private static let cappedAllowanceAnswerRepeats = 40

    /// The tool-output text that sizes a span so an
    /// ``answerStatingEachLineTwice()`` answer overruns its token budget while
    /// the distinct lines of that answer fit inside it — the band the free
    /// repair decides.
    private static let twiceStatedAnswerSpanToolOutput = String(repeating: summarySentence, count: 4)

    /// How many distinct lines ``answerStatingEachLineTwice()`` writes before it
    /// states them all a second time.
    ///
    /// Four is the fewest the stage's own repetition check reads, so the answer
    /// is judged rather than passed over as terse. Stating each line twice puts
    /// the repeated share at exactly one half, which is NOT past the share that
    /// makes an answer a loop, so the answer earns no repetition re-ask and the
    /// size ladder is what the test measures.
    private static let twiceStatedAnswerLineCount = 4

    /// An answer that states each of its lines twice.
    ///
    /// - Returns: The answer as the model wrote it, and its distinct lines
    ///   alone — what the free repair leaves.
    private static func answerStatingEachLineTwice() -> (answer: String, distinct: String) {
        let lines = (1...twiceStatedAnswerLineCount).map {
            "- Fact \($0) — the station archive keeps its records station by station."
        }
        let distinct = lines.joined(separator: "\n")
        return ("\(distinct)\n\(distinct)", distinct)
    }

    @Test("a condense re-ask never generates under a ceiling above the call that wrote the answer it condenses")
    func theCondenseReAskIsNeverSizedAboveTheCallThatWroteItsInput() async throws {
        // A model writes up to its ceiling. A condense call given MORE room
        // than the answer it must shorten is therefore free to answer with more
        // text than it was given, which is no condensation at all. The
        // 2026-09-01 real-model compaction measured exactly that: a ceiling of 628
        // against an input written under 617, and 3238 bytes out of 3153 in.
        // The stage's own `maxChunkTokens` bounds the condense allowance here,
        // rather than the 1,000,000 the other tests compact under, because that
        // cap is what parts the two allowances.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.cappedAllowanceSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4)
        let oversized = String(repeating: Self.summarySentence, count: Self.cappedAllowanceAnswerRepeats)
        let condensedAnswer = "The service reads its configuration from environment variables."
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [oversized, condensedAnswer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(oversized) > budget)  // sanity: the map answer overruns, so the condense rung fires

        #expect(outcome.ceilings.count == 2)
        let mapCeiling = try #require(outcome.ceilings.first)
        let condenseCeiling = try #require(outcome.ceilings.last)
        #expect(
            condenseCeiling <= mapCeiling,
            "the condense call ran under \(condenseCeiling) against an input written under \(mapCeiling)"
        )
    }

    @Test("an oversized answer's repeated lines are dropped before any condense re-ask, and an answer that then fits is stored whole")
    func repeatedLinesAreDroppedBeforeTheCondenseReAsk() async throws {
        // The free repair comes before the paid one. A line the answer had
        // already written states nothing new, so it must never occupy budget a
        // stated fact could hold, and it must never buy a generation either.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.twiceStatedAnswerSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let scripted = Self.answerStatingEachLineTwice()
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [scripted.answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        // Sanity: the answer as written really overruns the budget, and its
        // distinct lines really fit it, so the free repair is what decides.
        #expect(
            counter.count(scripted.answer) > budget,
            "the answer holds \(counter.count(scripted.answer)) tokens against a \(budget)-token budget")
        #expect(
            counter.count(scripted.distinct) <= budget,
            "the distinct lines hold \(counter.count(scripted.distinct)) tokens against a \(budget)-token budget")

        #expect(outcome.prompts.count == 1)
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == scripted.distinct)
        #expect(compacted.summaryCut == false)
    }

    @Test("a compaction that already re-asked about a repetition loop does not also re-ask to condense")
    func aCompactionSpendsOneRecoveryGenerationAndNoMore() async throws {
        // The ladder has two recovery rungs, and a compaction spends ONE generation
        // across both of them. The re-asked answer already carries the
        // strongest correction the stage states; asking a third time about the
        // same material buys a generation and no information. The 2026-09-01
        // compaction measured the third call answering with a repetition loop LONGER
        // than the text it had to shorten, which the compaction then discarded.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let outcome = try await Self.compactionOutcome(
            compacting: turns,
            with: stage,
            prompt: .default,
            answering: [Self.loopedAnswer(markedBy: { _ in "- " }), oversized]
        )

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(oversized) > budget)  // sanity: the re-asked answer overruns

        #expect(outcome.prompts.count == 2)
        #expect(try #require(outcome.prompts.last).contains(Summarization.repetitionRetryDirective))
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summaryCut)
        #expect(oversized.hasPrefix(compacted.summary))
    }

    @Test("a condense answer that repeats one line over and over is discarded, and the summary already in hand is kept")
    func aRepetitiveCondenseAnswerIsDiscarded() async throws {
        // Every other rung tests its answer for a repetition loop. This one
        // must too: a loop states almost nothing, so a compaction that stored it
        // would trade a real summary for a line written over and over.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let oversized = String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let looped = Self.loopedAnswer(markedBy: { _ in "- " })
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [oversized, looped])

        #expect(counter.count(looped) < counter.count(oversized))  // sanity: the loop is the smaller candidate

        #expect(outcome.prompts.count == 2)
        let compacted = try #require(outcome.compacted)
        #expect(!compacted.summary.contains(Self.loopedAnswerLine))
        #expect(oversized.hasPrefix(compacted.summary))
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
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        let kept = sections.prefix(Self.keptSectionCount).joined(separator: "\n")
        let oneSectionMore = sections.prefix(Self.keptSectionCount + 1).joined(separator: "\n")
        // Sanity: the kept sections really fit the budget, and one more really
        // does not, so the expected cut point is observable.
        #expect(counter.count(kept) <= budget)
        #expect(counter.count(oneSectionMore) > budget)

        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == kept)
        #expect(compacted.summaryCut)
    }

    @Test("when the sections a cut keeps run up to the last header, the cut keeps what fits of the final section rather than dropping it")
    func theFinalSectionIsCutRatherThanDroppedWhole() async throws {
        // The section alignment exists so a stored summary never stops inside a
        // section a LATER section follows — the `^51e9dyq` defect. There is no
        // later section to protect when the overrun sits in the final one, so
        // aligning there drops a whole section to shed a few tokens. The
        // real-model compaction of 2026-09-01 measured that trade: 906 bytes shed to
        // stay inside a budget the text overran by 41, and the fact stated last
        // in the span went with them.
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.sectionedCutSpanToolOutput)
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let sections = (1...(Self.keptSectionCount + 1)).map { Self.sectionedAnswerSection(index: $0) }
        let answer = sections.joined(separator: "\n")
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        let whole = sections.prefix(Self.keptSectionCount).joined(separator: "\n")
        // Sanity: the whole sections really fit, and the final section really
        // does not, so the cut point inside that final section is observable.
        #expect(counter.count(whole) <= budget)
        #expect(counter.count(answer) > budget)

        let compacted = try #require(outcome.compacted)
        #expect(compacted.summaryCut)
        #expect(counter.count(compacted.summary) <= budget)
        #expect(answer.hasPrefix(compacted.summary))
        #expect(
            counter.count(compacted.summary) > counter.count(whole),
            "the cut stored \(counter.count(compacted.summary)) tokens against \(counter.count(whole)) of whole sections"
        )
    }

    @Test("a sectioned answer whose first section overruns the whole budget falls back to the sentence boundary")
    func anOversizedFirstSectionFallsBackToTheSentenceBoundary() async throws {
        // When not even one whole section fits the budget, a section-aligned
        // cut would store nothing — the `^bgxtdk3` defect. The cut falls back
        // to the sentence boundary inside the first section instead, which is
        // the trade ``Summarization/cut(_:toTokens:counter:)`` documents.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let firstSection =
            "1. Intent — " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let answer = firstSection + "\n2. Next steps — none."
        let turns = try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput)
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        #expect(counter.count(firstSection) > budget)  // sanity: not even one whole section fits

        let compacted = try #require(outcome.compacted)
        #expect(compacted.summaryCut)
        #expect(answer.hasPrefix(compacted.summary))
        #expect(compacted.summary.hasSuffix("."))
        #expect(counter.count(compacted.summary) <= budget)
    }

    @Test("a short answer is stored word for word, with no condense pass and no cut")
    func aShortAnswerIsStoredUnchanged() async throws {
        // The bound is a bound, not a rewrite. A summarizer whose answer fits
        // the span budget gets it stored exactly as it wrote it.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let answer = "The batch size is a setting rather than a constant."
        let outcome = try await Self.compactionOutcome(
            compacting: try TranscriptFixtures.makeTurns(5, toolOutputText: Self.condensableSpanToolOutput),
            with: stage,
            prompt: .default,
            answering: [answer]
        )

        #expect(outcome.prompts.count == 1)
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == answer)
        #expect(compacted.summaryCut == false)
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
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summaryCut)
        #expect(counter.count(compacted.summary) <= budget)
        #expect(answer.hasPrefix(compacted.summary))
        #expect(compacted.summary.hasSuffix(word.trimmingCharacters(in: .whitespaces)))
    }

    @Test("an answer the cut finds no boundary in still carries text, so a compaction never stores nothing")
    func theCutNeverStoresAnEmptySummary() async throws {
        // An empty summary erases the span it replaced — the defect `^bgxtdk3`
        // measured on 19 of 19 gated seeds. A bound that could produce one
        // would trade that defect back in, so the last fallback of the cut is
        // the whole budget rather than a boundary that is not there.
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: Self.wholeSpanChunkTokens)
        let unbrokenRunLength = 900
        let answer = String(repeating: "x", count: unbrokenRunLength)
        let turns = try TranscriptFixtures.makeTurns(5)
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [answer, answer])

        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(1)))
        let compacted = try #require(outcome.compacted)
        #expect(!compacted.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(counter.count(compacted.summary) <= budget)
    }

    @Test("a chunked compaction hands each map call's answer to the reduce round whole — no per-call cut")
    func mapCallAnswersReachTheReduceRoundUncut() async throws {
        // The per-call ratio cut is the arithmetic task ^xx02yn6 removed: it
        // trimmed answers by position that the shrink invariant would accept.
        // An intermediate answer never enters the transcript, so the only
        // bound it needs is the generation ceiling it was written under; the
        // final summary is bounded against the span, once, where the
        // invariant lives.
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let oneTurnTokens = try counter.count(Transcript(entries: turns[0]))
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)
        let mapAnswerA = "A: " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let mapAnswerB = "B: " + String(repeating: Self.summarySentence, count: Self.summarySentenceRepeats)
        let finalAnswer = "final-combined-summary"
        let outcome = try await Self.compactionOutcome(
            compacting: turns, with: stage, prompt: .default, answering: [mapAnswerA, mapAnswerB, finalAnswer])

        // Sanity: the final answer fits the span budget, so no condense pass
        // follows the reduce round and the call count stays observable.
        let budget = try Self.expectedSummaryTokenBudget(compactingOld: Array(turns.prefix(2)))
        #expect(counter.count(finalAnswer) <= budget)

        // 2 map calls + 1 reduce call, and the reduce call reads both map
        // answers WHOLE — the old per-call cut would have trimmed each one
        // down to a share of its own chunk first.
        #expect(outcome.prompts.count == 3)
        let reducePrompt = outcome.prompts[2]
        #expect(reducePrompt.contains(mapAnswerA))
        #expect(reducePrompt.contains(mapAnswerB))
        #expect(try #require(outcome.compacted).summary == finalAnswer)
    }

    @Test("every call a chunked compaction makes is bounded by its own content, the reduce round over the chunk summaries included")
    func everyCallOfAChunkedCompactionIsBounded() async throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "result-\($0)") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        // One old turn per chunk (as `longSpanMapReducesAcrossChunks` sets up):
        // 2 map calls, then 1 reduce call over their summaries.
        let oneTurnTokens = try counter.count(Transcript(entries: turns[0]))
        let summarizer = ScriptedSummarizer(responses: ["chunk-summary-A", "chunk-summary-B", "final-combined-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: oneTurnTokens)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
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

        let maxChunkTokens = try counter.count(Transcript(entries: turns[0]))
        // Twice the chunk ceiling each, so `chunkStrings` can pair no two of
        // them and `reduce` takes its no-progress fallback over the whole
        // joined set — the one call that must ingest more than maxChunkTokens.
        // Under this counter a response of N tokens is a string of N characters.
        let oversizedSummaryTokens = maxChunkTokens * Self.oversizedResponseChunkMultiple
        let oversizedResponse = String(repeating: "y", count: oversizedSummaryTokens)
        let responses = (1...3).map { _ in oversizedResponse } + ["flat-fallback-summary"]
        let summarizer = ScriptedSummarizer(responses: responses)
        // A ratio above one half, because `summarizeOnce` now cuts every map
        // call's answer down to its own allowance. A chunk of `maxChunkTokens`
        // therefore yields a summary of `ratio * maxChunkTokens`, and
        // `chunkStrings` can pair two of those under `maxChunkTokens` for any
        // ratio at or below a half — so at the default 0.25 a compaction cannot reach
        // the no-progress fallback through a chunk this size at all. (It still
        // reaches it through a chunk SMALLER than
        // `Summarization.minimumSummaryTokens`, where the allowance floor
        // exceeds the chunk ceiling — the shape
        // `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible` compacts.)
        // The ratio is what this test needs to be doing the work, since the
        // bound it asserts is the cap rather than the floor.
        let pairingDefeatingRatio = 0.6
        let stage = Summarization(
            keepRecentTurns: 4, maxChunkTokens: maxChunkTokens, summaryTokenRatio: pairingDefeatingRatio)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        // 3 map calls + exactly 1 flat-fallback reduce call.
        #expect(summarizer.receivedMaxTokens.count == 4)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.last))
        // sanity: the fallback really does ingest more than a chunk's worth.
        #expect(counter.count(condensed) > maxChunkTokens)

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
        let unbounded = Int((Double(counter.count(condensed)) * stage.summaryTokenRatio).rounded(.up))
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

        // One old turn (5 turns, keepRecentTurns: 4), and `chunk(_:maxTokens:counter:)`
        // never splits a turn — so a chunk ceiling well under that turn's own
        // size still yields a single, oversized chunk and a single map call.
        let oneTurnTokens = try counter.count(Transcript(entries: turns[0]))
        let chunkCeilingDivisor = 8
        let maxChunkTokens = oneTurnTokens / chunkCeilingDivisor

        let summarizer = ScriptedSummarizer(responses: ["single-oversized-chunk-summary"])
        let stage = Summarization(keepRecentTurns: 4, maxChunkTokens: maxChunkTokens)

        _ = try await stage.apply(
            transcript,
            prompt: .default,
            tokensBefore: try counter.count(transcript),
            priorStagesApplied: [],
            summarizer: summarizer,
            counter: counter
        )

        #expect(summarizer.receivedMaxTokens.count == 1)
        let condensed = try Self.condensedContent(of: try #require(summarizer.receivedPrompts.first))
        // sanity: the lone turn really is bigger than a chunk may be.
        #expect(counter.count(condensed) > maxChunkTokens)

        let ceiling = try #require(summarizer.receivedMaxTokens.first)
        #expect(
            ceiling
                == Self.expectedCeiling(
                    condensing: condensed,
                    ratio: stage.summaryTokenRatio,
                    maxChunkTokens: stage.maxChunkTokens,
                    headroom: stage.reasoningTokenHeadroom))
        let unbounded = Int((Double(counter.count(condensed)) * stage.summaryTokenRatio).rounded(.up))
        #expect(ceiling - stage.reasoningTokenHeadroom < unbounded)
    }

    // MARK: - A repetition loop in a summarizer's answer is never stored as the compaction's memory

    /// The one line a degenerate answer writes over and over.
    ///
    /// Task ^49dy082 measured the shape against the real 1B model: under
    /// greedy decoding the model wrote one line 50 times and reached none of
    /// the facts the span stated after it.
    private static let loopedAnswerLine = "The archive keeps its records station by station."

    /// The distinct line a degenerate answer opens with, so a test can tell
    /// the answer's own content from the copies that follow it.
    private static let loopedAnswerOpening = "1. Intent — the user asked for the archive plan."

    /// How many copies of ``loopedAnswerLine`` one degenerate answer carries.
    ///
    /// Ten copies against one opening line put the repeated share at 0.91,
    /// far past the bound the stage applies, and keep the fixture readable.
    private static let loopedAnswerLineCount = 10

    /// A summary a scripted summarizer answers with that repeats no line —
    /// what the stage must store without asking again.
    private static let unrepetitiveAnswer = """
        1. Intent — the user asked for the archive plan.
        2. Stated facts — the batch size is a setting, and rejected rows go to a rejects file.
        3. Constraints & decisions — a station cuts over after seven clean reports.
        8. Next steps — run the comparison job nightly.
        """

    /// Builds a degenerate answer: ``loopedAnswerOpening``, then
    /// ``loopedAnswerLineCount`` copies of ``loopedAnswerLine``.
    ///
    /// - Parameter marker: The list marker each copy opens with, given the
    ///   copy's one-based number. A loop that renumbers its copies writes the
    ///   same line under a different marker.
    /// - Returns: The answer text.
    private static func loopedAnswer(markedBy marker: (Int) -> String) -> String {
        let copies = (1...loopedAnswerLineCount).map { "\(marker($0))\(loopedAnswerLine)" }
        return ([loopedAnswerOpening] + copies).joined(separator: "\n")
    }

    /// The stage and turns every repetition test compacts with: a span whose token
    /// budget is far wider than any answer below, so the size ladder never
    /// fires and the call count measures the repetition re-ask alone.
    ///
    /// - Returns: The turns to compact, and the stage to compact them with.
    /// - Throws: Whatever the fixture build throws.
    private static func repetitionFixture() throws -> (turns: [[Transcript.Entry]], stage: Summarization) {
        (
            try TranscriptFixtures.makeTurns(5, toolOutputText: largeSpanToolOutput),
            Summarization(keepRecentTurns: 4, maxChunkTokens: wholeSpanChunkTokens)
        )
    }

    @Test("a summarizer answer that repeats one line earns one re-ask, and the re-asked answer is what the compaction stores")
    func aLoopedAnswerEarnsOneReAsk() async throws {
        // The property this guards: a compaction is paid to carry facts forward, and
        // an answer that writes one line over and over carries none. The stage
        // used to store it, because it checked only that the answer was not
        // empty and not too large.
        let fixture = try Self.repetitionFixture()
        let outcome = try await Self.compactionOutcome(
            compacting: fixture.turns,
            with: fixture.stage,
            prompt: .default,
            answering: [Self.loopedAnswer(markedBy: { _ in "- " }), Self.unrepetitiveAnswer]
        )

        #expect(outcome.prompts.count == 2)
        let reAsk = try #require(outcome.prompts.last)
        #expect(reAsk.contains(Summarization.repetitionRetryDirective))
        // The re-ask condenses the same span, so the model answers the same
        // question rather than editing its own broken answer.
        #expect(try Self.condensedContent(of: reAsk) == Self.condensedContent(of: try #require(outcome.prompts.first)))

        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == Self.unrepetitiveAnswer)
    }

    @Test("a repetition loop that renumbers each copy is still caught, because a list marker is not content")
    func aRenumberedLoopIsCaught() async throws {
        // Measured on the real model: the loop wrote "24. User: …", "25. User:
        // …", so no two lines were byte-identical. Comparing the lines under
        // their list markers is what sees one line written eleven times.
        let fixture = try Self.repetitionFixture()
        let outcome = try await Self.compactionOutcome(
            compacting: fixture.turns,
            with: fixture.stage,
            prompt: .default,
            answering: [Self.loopedAnswer(markedBy: { "\($0). " }), Self.unrepetitiveAnswer]
        )

        #expect(outcome.prompts.count == 2)
        #expect(try #require(outcome.compacted).summary == Self.unrepetitiveAnswer)
    }

    @Test("when the re-ask loops as well, the compaction stores the first answer with its repeated lines removed")
    func aSecondLoopedAnswerIsStoredWithoutItsRepeats() async throws {
        // The stage never asks a third time — the compaction's call budget is one
        // map call and at most one recovery call for each rung of the ladder.
        // What it stores instead carries every line the model actually wrote,
        // once, so the repeats occupy none of the stored summary's budget.
        let fixture = try Self.repetitionFixture()
        let looped = Self.loopedAnswer(markedBy: { _ in "- " })
        let outcome = try await Self.compactionOutcome(
            compacting: fixture.turns,
            with: fixture.stage,
            prompt: .default,
            answering: [looped, Self.loopedAnswer(markedBy: { "\($0). " })]
        )

        #expect(outcome.prompts.count == 2)
        let compacted = try #require(outcome.compacted)
        #expect(compacted.summary == "\(Self.loopedAnswerOpening)\n- \(Self.loopedAnswerLine)")
        #expect(counter.count(looped) > counter.count(compacted.summary))
    }

    @Test("an answer that repeats no line is stored as it stands, and costs no second call")
    func anUnrepetitiveAnswerIsNotReAsked() async throws {
        let fixture = try Self.repetitionFixture()
        let outcome = try await Self.compactionOutcome(
            compacting: fixture.turns, with: fixture.stage, prompt: .default, answering: [Self.unrepetitiveAnswer])

        #expect(outcome.prompts.count == 1)
        #expect(try #require(outcome.compacted).summary == Self.unrepetitiveAnswer)
    }

    @Test("a short answer that says the same thing twice is not a loop, so it costs no re-ask")
    func aShortAnswerThatRepeatsALineIsNotALoop() async throws {
        // The bound needs a floor: two lines that agree are terse, not
        // degenerate, and re-asking for them would spend a generation on
        // nothing.
        let fixture = try Self.repetitionFixture()
        let terse = "\(Self.loopedAnswerLine)\n\(Self.loopedAnswerLine)"
        let outcome = try await Self.compactionOutcome(
            compacting: fixture.turns, with: fixture.stage, prompt: .default, answering: [terse])

        #expect(outcome.prompts.count == 1)
        #expect(try #require(outcome.compacted).summary == terse)
    }
}
