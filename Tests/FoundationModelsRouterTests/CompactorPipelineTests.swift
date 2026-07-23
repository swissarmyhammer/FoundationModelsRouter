import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task vvjfkfb (compaction epic — compaction_plan.md §1.3, §1.4):
/// ``Compactor``'s pipeline orchestration — stage ordering, early stop once a
/// stage lands under target, and the oversized-tail shortfall report.
///
/// Targets below are derived from actual estimates
/// (``Compactor/estimatedTokenCount(of:)``) rather than hand-computed
/// constants, so these tests assert the *mechanism* (before > target > after)
/// rather than pinning brittle numbers to the character-ratio heuristic's
/// exact JSON-encoding overhead.
@Suite("Compactor pipeline: stage ordering, early stop, oversized-tail shortfall")
struct CompactorPipelineTests {
    // MARK: - Fixtures
    //
    // makeInstructions()/makeTurn() live in TranscriptFixtures
    // (Helpers/TranscriptTestHelpers.swift), shared with CompactionStageTests.

    /// A budget whose `target` fraction of `limit` reconstructs `targetTokens`
    /// (a huge, fixed `limit` keeps the fraction well clear of rounding
    /// error).
    private static func makeBudget(targetTokens: Int) -> TokenBudget {
        let limit = 1_000_000
        return TokenBudget(limit: limit, trigger: 0.80, target: Double(targetTokens) / Double(limit))
    }

    // MARK: - Already under target: no stages run

    @Test("a transcript already under target needs no stages; it is returned unchanged")
    func alreadyUnderTargetRunsNoStages() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: "small result") }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let budget = Self.makeBudget(targetTokens: tokensBefore * 2)

        let (resultTranscript, result) = Compactor.compact(transcript, budget: budget)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == tokensBefore)
        #expect(result.summary == nil)
    }

    // MARK: - Early stop: elision alone suffices

    @Test("the pipeline stops after ToolOutputElision when eliding old tool output alone lands under target")
    func earlyStopAfterElisionAlone() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigOutput = String(repeating: "large tool result content ", count: 400)
        let turns = try (1...6).map { try TranscriptFixtures.makeTurn(index: $0, toolOutputText: bigOutput) }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let afterElision = Compactor.estimatedTokenCount(of: ToolOutputElision().apply(transcript))
        #expect(afterElision < tokensBefore)  // sanity: elision actually helps here

        let budget = Self.makeBudget(targetTokens: (tokensBefore + afterElision) / 2)

        let (resultTranscript, result) = Compactor.compact(transcript, budget: budget)

        #expect(result.stagesApplied == ["ToolOutputElision"])
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == afterElision)
        // Truncation never ran: old turns' prompts/tool calls are still present.
        #expect(Array(resultTranscript).contains { $0.id == "prompt-1" })
        #expect(Array(resultTranscript).contains { $0.id == "calls-1" })
    }

    // MARK: - Stage ordering: both stages needed, in order

    @Test("when elision alone is insufficient, TurnTruncation runs next, in order")
    func bothStagesRunInOrderWhenNeeded() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "large content ", count: 400)
        // Old turns are large everywhere (prompt, tool output, response), so
        // eliding tool output alone can't be enough — only dropping the
        // whole turn (TurnTruncation) gets under target.
        let turns = try (1...6).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let afterElision = Compactor.estimatedTokenCount(of: ToolOutputElision().apply(transcript))
        let afterBoth = Compactor.estimatedTokenCount(of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        #expect(afterBoth < afterElision)  // sanity: truncation is still needed after elision

        let budget = Self.makeBudget(targetTokens: (afterElision + afterBoth) / 2)

        let (resultTranscript, result) = Compactor.compact(transcript, budget: budget)

        #expect(result.stagesApplied == ["ToolOutputElision", "TurnTruncation"])
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == afterBoth)
        // Old turns are gone entirely now.
        #expect(!Array(resultTranscript).contains { $0.id == "prompt-1" })
        // The recency window survives verbatim.
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }
        #expect(Array(resultTranscript).suffix(expectedRecentTail.count) == expectedRecentTail)
    }

    // MARK: - Oversized tail: shortfall reported, transcript unchanged

    @Test("when the recency window alone exceeds target, the pipeline reports the shortfall and returns the transcript unchanged")
    func oversizedTailReturnsUnchangedWithShortfall() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "big ", count: 2000)
        // Only 2 turns — fewer than the default keepRecentTurns (4), so every
        // turn is inside the untouchable recency window: neither stage can
        // fold anything away, however oversized the transcript is.
        let turns = try (1...2).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let budget = Self.makeBudget(targetTokens: tokensBefore / 2)

        let (resultTranscript, result) = Compactor.compact(transcript, budget: budget)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.tokensBefore == tokensBefore)
        #expect(result.tokensAfter == tokensBefore)
        // The shortfall is visible: tokensAfter is still over target.
        let targetTokens = Int(Double(budget.limit) * budget.target)
        #expect(result.tokensAfter > targetTokens)
    }

    @Test(
        "oversized tail with non-empty old turns: tokensAfter reflects the unchanged returned transcript, not the discarded fully-folded attempt"
    )
    func oversizedTailWithOldTurnsReportsTokensAfterForTheReturnedTranscript() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigText = String(repeating: "big content ", count: 400)
        // 6 turns: turns 1-2 are old (foldable away), turns 3-6 are the
        // recency window — but even that reduced recency window alone is
        // still huge enough to exceed target, so this is a genuine
        // oversized-tail case where `current` (the fully-elided-and-truncated
        // attempt inside the pipeline loop) is smaller than `transcript` yet
        // the function must still return `transcript` unchanged.
        let turns = try (1...6).map {
            try TranscriptFixtures.makeTurn(index: $0, promptText: bigText, toolOutputText: bigText, responseText: bigText)
        }
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let tokensBefore = Compactor.estimatedTokenCount(of: transcript)
        let afterBoth = Compactor.estimatedTokenCount(of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        #expect(afterBoth < tokensBefore)  // sanity: folding away old turns does shrink the discarded attempt

        // Target below even the best the deterministic stages can achieve.
        let budget = Self.makeBudget(targetTokens: afterBoth / 2)

        let (resultTranscript, result) = Compactor.compact(transcript, budget: budget)

        #expect(resultTranscript == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.tokensBefore == tokensBefore)
        // Must report the size of what's actually returned (the unchanged
        // original), not the size of the discarded, more-reduced attempt.
        #expect(result.tokensAfter == tokensBefore)
    }
}
