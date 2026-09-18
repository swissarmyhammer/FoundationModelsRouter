import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the host-supplied ``ToolOutputProtection`` rule against each
/// compaction stage on its own, and against the ``Compactor`` pipeline.
///
/// Every fixture holds one protected tool output (a loaded skill body) and one
/// unprotected tool output (a search result), each in a turn older than the
/// recency window. A protected output must stay in the transcript word for
/// word through every stage. An unprotected output compacts as before.
@Suite("Tool output protection through the compaction stages")
struct ToolOutputProtectionTests {
    /// The fixtures every test here reads.
    private typealias Fixtures = ProtectedToolOutputFixtures

    /// The fixed text the recording summarizer answers with.
    private static let summaryText = "1. Summary of the old turns."

    /// A summarizer that records each prompt it gets and answers with
    /// ``summaryText``.
    private actor RecordingSummarizer: CompactionSummarizer {
        /// Every prompt this summarizer got, in order.
        private(set) var prompts: [String] = []

        func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
            prompts.append(prompt)
            return ToolOutputProtectionTests.summaryText
        }
    }

    /// The entries `stage` leaves of the fixture transcript.
    ///
    /// - Parameter stage: The deterministic stage to apply.
    /// - Returns: The entries after the stage ran.
    /// - Throws: What the fixture builders throw.
    private static func entries(after stage: some CompactionStage) throws -> [Transcript.Entry] {
        Array(stage.apply(try Fixtures.transcript()))
    }

    // MARK: - ToolOutputElision

    @Test("ToolOutputElision keeps a protected tool output word for word")
    func elisionKeepsTheProtectedOutput() throws {
        let result = try Self.entries(after: ToolOutputElision(protection: Fixtures.rule))

        #expect(Fixtures.outputText(in: result, id: Fixtures.skillCallId) == Fixtures.skillBody)
    }

    @Test("ToolOutputElision still elides a tool output the rule does not protect")
    func elisionElidesTheUnprotectedOutput() throws {
        let result = try Self.entries(after: ToolOutputElision(protection: Fixtures.rule))

        let searchText = try #require(Fixtures.outputText(in: result, id: Fixtures.searchCallId))
        #expect(searchText == "[elided: original \"\(Fixtures.searchToolName)\" output omitted by compaction]")
    }

    @Test("ToolOutputElision with no rule elides the skill output, the behavior before the rule existed")
    func elisionWithoutARuleElidesEveryOldOutput() throws {
        let result = try Self.entries(after: ToolOutputElision())

        #expect(Fixtures.outputText(in: result, id: Fixtures.skillCallId) != Fixtures.skillBody)
    }

    @Test("the rule sees the call, so a skills call that loads no skill is not protected")
    func ruleReadsTheCallArguments() throws {
        let listTurn: [Transcript.Entry] = [
            Fixtures.prompt(id: "prompt-list"),
            Fixtures.toolCalls(
                id: "calls-list",
                [try Fixtures.skillsCall(id: Fixtures.listCallId, operation: Fixtures.listSkillsOperation)]),
            Fixtures.toolOutput(
                callId: Fixtures.listCallId, toolName: Fixtures.skillsToolName, text: Fixtures.skillListOutput),
            Fixtures.response(id: "response-list"),
        ]
        let transcript = Transcript(
            entries: [TranscriptFixtures.makeInstructions()] + listTurn + Fixtures.recentTurns())

        let result = Array(ToolOutputElision(protection: Fixtures.rule).apply(transcript))

        #expect(Fixtures.outputText(in: result, id: Fixtures.listCallId) != Fixtures.skillListOutput)
    }

    // MARK: - TurnTruncation

    @Test("TurnTruncation keeps the protected call and its output right after the header, in their original order")
    func truncationMovesTheProtectedPairAfterTheHeader() throws {
        let result = try Self.entries(after: TurnTruncation(protection: Fixtures.rule))

        let expected =
            [TranscriptFixtures.makeInstructions(), try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry]
            + Fixtures.recentTurns()
        #expect(result == expected)
    }

    @Test("TurnTruncation reduces a toolCalls entry to its protected calls, so each kept output keeps its call")
    func truncationReducesAMixedToolCallsEntry() throws {
        let skillCall = try Fixtures.skillsCall(id: Fixtures.skillCallId, operation: Fixtures.useSkillOperation)
        let mixedTurn: [Transcript.Entry] = [
            Fixtures.prompt(id: "prompt-mixed"),
            Fixtures.toolCalls(id: "calls-mixed", [try Fixtures.searchCall(id: Fixtures.searchCallId), skillCall]),
            Fixtures.toolOutput(
                callId: Fixtures.searchCallId, toolName: Fixtures.searchToolName, text: Fixtures.searchOutput),
            Fixtures.skillOutputEntry,
            Fixtures.response(id: "response-mixed"),
        ]
        let transcript = Transcript(
            entries: [TranscriptFixtures.makeInstructions()] + mixedTurn + Fixtures.recentTurns())

        let result = Array(TurnTruncation(protection: Fixtures.rule).apply(transcript))

        let reducedCalls = Fixtures.toolCalls(
            id: "calls-mixed" + ProtectedToolOutputs.reducedToolCallsIdSuffix, [skillCall])
        let expected =
            [TranscriptFixtures.makeInstructions(), reducedCalls, Fixtures.skillOutputEntry] + Fixtures.recentTurns()
        #expect(result == expected)
    }

    @Test("TurnTruncation with no rule drops every old turn, the behavior before the rule existed")
    func truncationWithoutARuleDropsEveryOldTurn() throws {
        let result = try Self.entries(after: TurnTruncation())

        #expect(result == [TranscriptFixtures.makeInstructions()] + Fixtures.recentTurns())
    }

    // MARK: - Summarization

    @Test("Summarization keeps a protected output word for word and never replaces it with summary text")
    func summarizationKeepsTheProtectedPair() async throws {
        let transcript = try Fixtures.transcript()
        let summarizer = RecordingSummarizer()

        let folded = try #require(
            try await Summarization().apply(
                transcript, prompt: .default, tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [], summarizer: summarizer, protection: Fixtures.rule))

        let result = Array(folded.transcript)
        let expectedPrefix = [
            TranscriptFixtures.makeInstructions(), try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry,
        ]
        #expect(Array(result.prefix(expectedPrefix.count)) == expectedPrefix)
        #expect(result[expectedPrefix.count].id == folded.summaryEntryId)
        #expect(Fixtures.outputText(in: result, id: Fixtures.searchCallId) == nil)
    }

    @Test("Summarization never sends a protected output to the summarizer")
    func summarizationDoesNotSummarizeTheProtectedOutput() async throws {
        let transcript = try Fixtures.transcript()
        let summarizer = RecordingSummarizer()

        _ = try await Summarization().apply(
            transcript, prompt: .default, tokensBefore: Compactor.estimatedTokenCount(of: transcript),
            priorStagesApplied: [], summarizer: summarizer, protection: Fixtures.rule)

        let prompts = await summarizer.prompts
        #expect(!prompts.isEmpty)
        #expect(prompts.allSatisfy { !$0.contains(Fixtures.skillBody) })
        #expect(prompts.contains { $0.contains(Fixtures.searchOutput) })
    }

    @Test("a Summarization fold names the kept protected entries in its live window, and folds the rest")
    func summarizationCheckpointNamesTheKeptEntries() async throws {
        let transcript = try Fixtures.transcript()

        let folded = try #require(
            try await Summarization().apply(
                transcript, prompt: .default, tokensBefore: Compactor.estimatedTokenCount(of: transcript),
                priorStagesApplied: [], summarizer: RecordingSummarizer(), protection: Fixtures.rule))

        let summaryEntry = try #require(Array(folded.transcript).first { $0.id == folded.summaryEntryId })
        let content = try #require(try Self.checkpointContent(of: summaryEntry))
        #expect(content.liveWindowEntryIds == Array(folded.transcript).map(\.id))
        #expect(!content.foldedEntryIds.contains(Fixtures.skillCallId))
        #expect(content.foldedEntryIds.contains(Fixtures.searchCallId))
    }

    /// The fold manifest a boundary entry carries.
    ///
    /// - Parameter entry: The boundary entry.
    /// - Returns: The manifest, or `nil` when `entry` carries none.
    /// - Throws: What `CompactionSegment(structuredSegment:)` throws.
    private static func checkpointContent(of entry: Transcript.Entry) throws -> CompactionSegment.Content? {
        guard case .response(let response) = entry else { return nil }
        for case .structure(let segment) in response.segments {
            if let compaction = try CompactionSegment(structuredSegment: segment) {
                return compaction.content
            }
        }
        return nil
    }

    // MARK: - Compactor

    @Test("the Compactor keeps a protected output through its deterministic stages and reports its size")
    func compactorKeepsTheProtectedOutput() async throws {
        let transcript = try Fixtures.transcript()
        let before = Compactor.estimatedTokenCount(of: transcript)
        let budget = TokenBudget(limit: before, target: Self.nearlyWholeTarget)

        let (folded, result) = try await Compactor.compact(transcript, budget: budget, protection: Fixtures.rule)

        #expect(!result.stagesApplied.isEmpty)
        #expect(Fixtures.outputText(in: Array(folded), id: Fixtures.skillCallId) == Fixtures.skillBody)
        #expect(result.protectedTokens == Self.protectedOutputTokens)
    }

    @Test("the Compactor completes a fold whose protected content alone is over the target, and reports it")
    func compactorCompletesAFoldOverTargetBecauseOfProtectedContent() async throws {
        let transcript = try Fixtures.transcript()
        let budget = Self.budgetUnderTheRecencyWindow(of: transcript)

        let (folded, result) = try await Compactor.compact(transcript, budget: budget, protection: Fixtures.rule)

        #expect(result.stagesApplied == [ToolOutputElision.stageName, TurnTruncation.stageName])
        #expect(result.tokensAfter < result.tokensBefore)
        #expect(result.tokensAfter > budget.targetTokens)
        #expect(result.protectedTokens == Self.protectedOutputTokens)
        #expect(Fixtures.outputText(in: Array(folded), id: Fixtures.skillCallId) == Fixtures.skillBody)
        #expect(Fixtures.outputText(in: Array(folded), id: Fixtures.searchCallId) == nil)
    }

    @Test("with no rule, a fold that cannot reach its target still returns the transcript unchanged")
    func compactorWithoutARuleKeepsTheShortfallExit() async throws {
        let transcript = try Fixtures.transcript()

        let (folded, result) = try await Compactor.compact(
            transcript, budget: Self.budgetUnderTheRecencyWindow(of: transcript))

        #expect(result.stagesApplied.isEmpty)
        #expect(folded == transcript)
        #expect(result.protectedTokens == 0)
    }

    /// The target fraction a budget states when the fold must shrink the
    /// transcript only a little: the deterministic stages always land under it.
    private static let nearlyWholeTarget = 0.9

    /// The estimated size of the protected tool output the fixture holds.
    private static let protectedOutputTokens = Compactor.estimatedTokenCount(
        of: Transcript(entries: [Fixtures.skillOutputEntry]))

    /// A budget whose target is half the header and recency window of
    /// `transcript`, so no deterministic stage can reach it, and the protected
    /// output alone is over it.
    ///
    /// - Parameter transcript: The transcript to fold.
    /// - Returns: The budget.
    private static func budgetUnderTheRecencyWindow(of transcript: Transcript) -> TokenBudget {
        let before = Compactor.estimatedTokenCount(of: transcript)
        let targetTokens = recencyWindowOnlyEstimate(Array(transcript)) / foldTargetMidpointDivisor
        return TokenBudget(limit: before, target: Double(targetTokens) / Double(before))
    }
}
