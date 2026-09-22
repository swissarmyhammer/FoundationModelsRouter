import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the one summarizer call of ``Compactor``: what the call gets,
/// the size it allows the summary, when it makes no call, and the snapshot
/// that restarts the live context.
///
/// Every size is counted by ``characterTokenCounter``, one token per
/// `Character`, so each size in a test is exact.
@Suite("One-call compaction: input, allowed size, snapshot and checkpoint")
struct OneCallCompactionTests {
    /// A live context of instructions and one turn with a tool call. Each
    /// text is distinct, so a test can find it in the prompt the summarizer
    /// got.
    ///
    /// - Returns: The live context.
    /// - Throws: What the fixture builders throw.
    private static func distinctTranscript() throws -> Transcript {
        Transcript(
            entries: [TranscriptFixtures.makeInstructions()]
                + (try TranscriptFixtures.makeTurn(
                    index: 1, promptText: "distinct-question", toolOutputText: "distinct-output",
                    responseText: "distinct-answer")))
    }

    /// The pending runs the tests that carry runs give the compaction.
    private static let pendingRuns = [
        CompactionSegment.PendingRunSummary(
            completionToken: "token-a", op: "run build", latestProgressDetail: "compiling"),
        CompactionSegment.PendingRunSummary(completionToken: "token-b", op: "run tests", latestProgressDetail: nil),
    ]

    /// The one prompt `summarizer` got.
    ///
    /// - Parameter summarizer: The summarizer to read.
    /// - Returns: The prompt.
    /// - Throws: When the summarizer did not get exactly one prompt.
    private static func onlyPrompt(of summarizer: RecordingSummarizer) async throws -> String {
        let prompts = await summarizer.prompts
        try #require(prompts.count == 1)
        return prompts[0]
    }

    // MARK: - Input

    @Test("the prompt holds the compaction prompt, the stated size and the render of every entry, the instructions included")
    func inputHoldsPromptSizeAndEveryEntry() async throws {
        let transcript = try Self.distinctTranscript()
        let budget = summarizingCompactionBudget(for: Array(transcript))
        let summarizer = RecordingSummarizer(summary: "short summary")

        _ = try await compactWithUnboundedWindow(transcript, budget: budget, summarizer: summarizer)

        let prompt = try await Self.onlyPrompt(of: summarizer)
        let allowed = budget.targetTokens - characterCount(of: [TranscriptFixtures.makeInstructions()])
        #expect(prompt.hasPrefix(CompactionPrompt.default.text))
        #expect(prompt.contains("Size budget: about \(allowed) tokens."))
        for line in [
            "Instructions: you are a helpful assistant", "User: distinct-question", "Tool call: search(",
            "Tool output (search): distinct-output", "Assistant: distinct-answer",
        ] {
            #expect(prompt.contains(line))
        }
    }

    @Test("a custom prompt's text is sent in place of the default, and its name goes into the checkpoint")
    func customPromptIsSentAndNamed() async throws {
        let custom = CompactionPrompt(name: "custom-prompt-name", text: "CUSTOM COMPACTION INSTRUCTIONS.")
        let transcript = try Self.distinctTranscript()
        let summarizer = RecordingSummarizer(summary: "short summary")

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: summarizingCompactionBudget(for: Array(transcript)), summarizer: summarizer,
            prompt: custom)

        let prompt = try await Self.onlyPrompt(of: summarizer)
        #expect(prompt.hasPrefix(custom.text))
        #expect(!prompt.contains(CompactionPrompt.default.text))
        let summaryEntry = try #require(Array(compacted).first { $0.id == result.summaryEntryId })
        #expect(try checkpointContent(of: summaryEntry)?.promptName == custom.name)
    }

    // MARK: - Allowed size

    @Test("the allowed size is the target less the instructions, the protected entries and the pending-runs rendering")
    func allowedSizeIsTheTargetLessWhatTheSnapshotKeeps() async throws {
        let transcript = try ProtectedToolOutputFixtures.transcript()
        let budget = try budgetJustUnder(transcript)
        let summarizer = RecordingSummarizer(summary: "short summary")

        _ = try await compactWithUnboundedWindow(
            transcript, budget: budget, summarizer: summarizer, pendingRuns: Self.pendingRuns,
            protection: ProtectedToolOutputFixtures.rule)

        let kept = [
            TranscriptFixtures.makeInstructions(), try ProtectedToolOutputFixtures.skillCallsEntry(),
            ProtectedToolOutputFixtures.skillOutputEntry,
        ]
        let rendering = characterTokenCounter.count(CompactionSegment.renderedPendingRuns(Self.pendingRuns))
        let allowed = budget.targetTokens - characterCount(of: kept) - rendering
        #expect(try await Self.onlyPrompt(of: summarizer).contains("Size budget: about \(allowed) tokens."))
    }

    @Test("a target smaller than the instructions leaves no room for a summary: no call, the live context stays")
    func targetUnderTheInstructionsLeavesNoRoom() async throws {
        let instructionsTokens = 40
        let promptTokens = 40
        let targetTokens = 30
        let transcript = Transcript(entries: [
            SizedEntries.instructions(id: "instructions", tokens: instructionsTokens),
            SizedEntries.prompt(id: "prompt", tokens: promptTokens),
        ])
        let budget = TokenBudget(limit: targetTokens, target: 1)
        let summarizer = RecordingSummarizer(summary: "short summary")

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: budget, summarizer: summarizer)

        #expect(result.shortfall == .targetLeavesNoRoomForSummary(allowedSummaryTokens: targetTokens - instructionsTokens))
        #expect(compacted == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summaryEntryId == nil)
        #expect(await summarizer.prompts.isEmpty)
    }

    @Test("a live context already under the target is returned unchanged, with no call and no shortfall")
    func contextUnderTargetIsUnchanged() async throws {
        let transcript = try Self.distinctTranscript()
        let before = characterCount(of: Array(transcript))
        let summarizer = RecordingSummarizer(summary: "short summary")

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: TokenBudget(limit: before, target: 1), summarizer: summarizer)

        #expect(compacted == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.shortfall == nil)
        #expect(result.tokensBefore == before)
        #expect(result.tokensAfter == before)
        #expect(await summarizer.prompts.isEmpty)
    }

    // MARK: - The shrink check

    @Test("a summary that does not make the live context smaller is discarded: the original returns with the snapshot's size")
    func summaryThatDoesNotShrinkIsDiscarded() async throws {
        let transcript = try Self.distinctTranscript()
        let before = characterCount(of: Array(transcript))
        let longSummary = SizedEntries.text(tokens: before, letter: "s")

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: summarizingCompactionBudget(for: Array(transcript)),
            summarizer: RecordingSummarizer(summary: longSummary))

        let snapshotTokens = characterCount(of: [TranscriptFixtures.makeInstructions()]) + longSummary.count
        #expect(result.shortfall == .summaryDidNotShrinkContext(snapshotTokens: snapshotTokens))
        #expect(compacted == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(result.tokensAfter == before)
    }

    // MARK: - Failures

    @Test("a summary with no text, or with whitespace only, is a failure and never a stored summary", arguments: ["", " \n\t "])
    func emptySummaryThrows(summary: String) async throws {
        let transcript = try Self.distinctTranscript()

        await #expect(throws: SummarizationError.emptySummary) {
            _ = try await compactWithUnboundedWindow(
                transcript, budget: summarizingCompactionBudget(for: Array(transcript)),
                summarizer: RecordingSummarizer(summary: summary))
        }
    }

    // MARK: - Snapshot

    @Test("the snapshot is the instructions, one summary entry and the kept protected entries, and no turn of the conversation")
    func snapshotShape() async throws {
        let transcript = try ProtectedToolOutputFixtures.transcript()
        let summary = "1. Intent — the summary."

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: try budgetJustUnder(transcript), summarizer: RecordingSummarizer(summary: summary),
            protection: ProtectedToolOutputFixtures.rule)

        let entries = Array(compacted)
        let summaryEntryId = try #require(result.summaryEntryId)
        #expect(summaryEntryId.hasPrefix("compaction-summary-"))
        #expect(entries.first == TranscriptFixtures.makeInstructions())
        #expect(entries[1].id == summaryEntryId)
        let kept = [try ProtectedToolOutputFixtures.skillCallsEntry(), ProtectedToolOutputFixtures.skillOutputEntry]
        #expect(Array(entries.dropFirst(2)) == kept)
        guard case .response(let response) = entries[1], case .text(let text) = response.segments.first else {
            Issue.record("the summary entry must be a response whose first segment is the summary text")
            return
        }
        #expect(text.content == summary)
    }

    @Test("the summary entry carries the pending-runs rendering as a second text segment")
    func summaryEntryCarriesThePendingRuns() async throws {
        // A live context larger than the pending-runs rendering, so the target
        // leaves room for a summary next to it.
        let transcript = try ProtectedToolOutputFixtures.transcript()

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: try budgetJustUnder(transcript), summarizer: RecordingSummarizer(summary: "summary"),
            pendingRuns: Self.pendingRuns)

        let summaryEntry = try #require(Array(compacted).first { $0.id == result.summaryEntryId })
        guard case .response(let response) = summaryEntry else {
            Issue.record("the summary entry must be a response")
            return
        }
        let texts = response.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        #expect(texts == ["summary", CompactionSegment.renderedPendingRuns(Self.pendingRuns)])
        #expect(try checkpointContent(of: summaryEntry)?.pendingRuns == Self.pendingRuns)
    }

    @Test("the checkpoint names the live window, every compacted entry, the one stage, the prompt and both sizes")
    func checkpointNamesWindowStageAndSizes() async throws {
        let transcript = try Self.distinctTranscript()
        let before = characterCount(of: Array(transcript))

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: summarizingCompactionBudget(for: Array(transcript)),
            summarizer: RecordingSummarizer(summary: "summary"))

        let summaryEntry = try #require(Array(compacted).first { $0.id == result.summaryEntryId })
        let content = try #require(try checkpointContent(of: summaryEntry))
        let instructionsId = TranscriptFixtures.makeInstructions().id
        #expect(content.liveWindowEntryIds == [instructionsId, summaryEntry.id])
        #expect(content.compactedEntryIds == Array(transcript).map(\.id).filter { $0 != instructionsId })
        #expect(content.stagesApplied == [Summarization.stageName])
        #expect(content.promptName == CompactionPrompt.default.name)
        #expect(content.tokensBefore == before)
        #expect(content.tokensAfter == characterCount(of: Array(compacted)))
        #expect(content.pendingRuns == nil)
        #expect(result.tokensBefore == content.tokensBefore)
        #expect(result.tokensAfter == content.tokensAfter)
        #expect(result.stagesApplied == content.stagesApplied)
        #expect(result.summary == "summary")
        #expect(result.shortfall == nil)
    }
}
