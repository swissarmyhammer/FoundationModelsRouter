import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the host-supplied ``ToolOutputProtection`` rule against the
/// one-call compaction of ``Compactor``.
///
/// Every fixture holds one protected tool output (a loaded skill body) and one
/// unprotected tool output (a search result). The new snapshot must keep a
/// protected output word for word next to the summary. The summary replaces
/// an unprotected output.
@Suite("Tool output protection through the one-call compaction")
struct ToolOutputProtectionTests {
    /// The fixtures every test here reads.
    private typealias Fixtures = ProtectedToolOutputFixtures

    /// The fixed text the shared ``RecordingSummarizer`` answers with.
    private static let summaryText = "1. Summary of the conversation."

    /// Compacts `transcript` with a target one token under its size, so the
    /// summary gets almost all of the room.
    ///
    /// - Parameters:
    ///   - transcript: The live context to compact.
    ///   - summarizer: The summarizer the call goes to.
    ///   - protection: The host rule, or `nil` to protect nothing.
    /// - Returns: The new live context and the result.
    /// - Throws: What the compaction throws.
    private static func compact(
        _ transcript: Transcript, summarizer: RecordingSummarizer, protection: ToolOutputProtection?
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        try await compactWithUnboundedWindow(
            transcript, budget: try budgetJustUnder(transcript), summarizer: summarizer, protection: protection)
    }

    @Test("the one-call compaction keeps the protected call and its output word for word, right after the summary")
    func compactionKeepsTheProtectedPairAfterTheSummary() async throws {
        let transcript = try Fixtures.transcript()

        let (compacted, result) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: Fixtures.rule)

        let entries = Array(compacted)
        let summaryEntryId = try #require(result.summaryEntryId)
        let keptPair = [try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry]
        #expect(entries.map(\.id) == [TranscriptFixtures.makeInstructions().id, summaryEntryId] + keptPair.map(\.id))
        #expect(Array(entries.suffix(keptPair.count)) == keptPair)
        #expect(Fixtures.outputText(in: entries, id: Fixtures.searchCallId) == nil)
    }

    @Test("the one-call compaction reduces a toolCalls entry to its protected calls, so each kept output keeps its call")
    func compactionReducesAMixedToolCallsEntry() async throws {
        let skillCall = try Fixtures.skillsCall(id: Fixtures.skillCallId, operation: Fixtures.useSkillOperation)
        let mixedAnswer: [Transcript.Entry] = [
            Fixtures.prompt(id: "prompt-mixed"),
            Fixtures.toolCalls(id: "calls-mixed", [try Fixtures.searchCall(id: Fixtures.searchCallId), skillCall]),
            Fixtures.toolOutput(
                callId: Fixtures.searchCallId, toolName: Fixtures.searchToolName, text: Fixtures.searchOutput),
            Fixtures.skillOutputEntry,
            Fixtures.response(id: "response-mixed"),
        ]
        let transcript = Transcript(
            entries: [TranscriptFixtures.makeInstructions()] + mixedAnswer + Fixtures.recentAnswers())

        let (compacted, _) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: Fixtures.rule)

        let reducedCalls = Fixtures.toolCalls(
            id: "calls-mixed" + ProtectedToolOutputs.reducedToolCallsIdSuffix, [skillCall])
        let kept = [reducedCalls, Fixtures.skillOutputEntry]
        #expect(Array(Array(compacted).suffix(kept.count)) == kept)
    }

    @Test("the rule sees the call, so a skills call that loads no skill is not protected")
    func ruleReadsTheCallArguments() async throws {
        let listAnswer: [Transcript.Entry] = [
            Fixtures.prompt(id: "prompt-list"),
            Fixtures.toolCalls(
                id: "calls-list",
                [try Fixtures.skillsCall(id: Fixtures.listCallId, operation: Fixtures.listSkillsOperation)]),
            Fixtures.toolOutput(
                callId: Fixtures.listCallId, toolName: Fixtures.skillsToolName, text: Fixtures.skillListOutput),
            Fixtures.response(id: "response-list"),
        ]
        let transcript = Transcript(
            entries: [TranscriptFixtures.makeInstructions()] + listAnswer + Fixtures.recentAnswers())

        let (compacted, result) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: Fixtures.rule)

        #expect(Fixtures.outputText(in: Array(compacted), id: Fixtures.listCallId) == nil)
        #expect(result.protectedTokens == 0)
    }

    @Test("the summarizer reads the whole live context, the protected output included")
    func summarizerReadsTheProtectedOutputToo() async throws {
        let transcript = try Fixtures.transcript()
        let summarizer = RecordingSummarizer(summary: Self.summaryText)

        _ = try await Self.compact(transcript, summarizer: summarizer, protection: Fixtures.rule)

        let prompt = try #require(await summarizer.prompts.first)
        #expect(prompt.contains(Fixtures.skillBody))
        #expect(prompt.contains(Fixtures.searchOutput))
    }

    @Test("the checkpoint names the kept protected entries in its live window, and every other entry as compacted")
    func checkpointNamesTheKeptEntries() async throws {
        let transcript = try Fixtures.transcript()

        let (compacted, result) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: Fixtures.rule)

        let summaryEntry = try #require(Array(compacted).first { $0.id == result.summaryEntryId })
        let content = try #require(try checkpointContent(of: summaryEntry))
        #expect(content.liveWindowEntryIds == Array(compacted).map(\.id))
        let liveIds = Set(content.liveWindowEntryIds)
        #expect(content.compactedEntryIds == Array(transcript).map(\.id).filter { !liveIds.contains($0) })
        #expect(content.compactedEntryIds.contains(Fixtures.searchCallId))
    }

    @Test("with no rule, the compaction keeps no tool output: the summary replaces the skill output too")
    func compactionWithoutARuleKeepsNoOutput() async throws {
        let transcript = try Fixtures.transcript()

        let (compacted, result) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: nil)

        let summaryEntryId = try #require(result.summaryEntryId)
        #expect(Array(compacted).map(\.id) == [TranscriptFixtures.makeInstructions().id, summaryEntryId])
        #expect(result.protectedTokens == 0)
    }

    @Test("the result reports the size of the kept protected output and of the call that made it")
    func resultReportsTheProtectedSize() async throws {
        let transcript = try Fixtures.transcript()

        let (_, result) = try await Self.compact(
            transcript, summarizer: RecordingSummarizer(summary: Self.summaryText), protection: Fixtures.rule)

        let keptPair = [try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry]
        #expect(result.protectedTokens == characterCount(of: keptPair))
    }

    @Test("a target that the instructions and the protected pair fill leaves no room for a summary: no call, no change")
    func protectedContentThatFillsTheTargetLeavesNoRoom() async throws {
        let transcript = try Fixtures.transcript()
        let before = try characterTokenCounter.count(transcript)
        let filled = characterCount(
            of: [TranscriptFixtures.makeInstructions(), try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry])
        let budget = TokenBudget(limit: before, target: Double(filled) / Double(before))
        let summarizer = RecordingSummarizer(summary: Self.summaryText)

        let (compacted, result) = try await compactWithUnboundedWindow(
            transcript, budget: budget, summarizer: summarizer, protection: Fixtures.rule)

        #expect(result.shortfall == .targetLeavesNoRoomForSummary(allowedSummaryTokens: 0))
        #expect(compacted == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(await summarizer.prompts.isEmpty)
    }
}
