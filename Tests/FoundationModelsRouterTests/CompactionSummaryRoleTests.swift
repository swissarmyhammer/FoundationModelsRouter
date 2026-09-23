import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Proves that the summary entry of a compaction reaches the model as a user
/// message with a header, and that a cold transcript still reads it as a
/// compaction row (task ^5t72pdx).
///
/// Measured on Qwen3.8-27B before this task: after a turn-start compaction,
/// the summary kept "Port 6543", but the summary was an assistant message
/// that the model did not write. The model answered "I do not have access
/// to your specific infrastructure configuration".
@Suite("Compaction summary role: the summary is a user message with a header")
struct CompactionSummaryRoleTests {
    /// The summary text every test compacts to.
    private static let summary = "Key value: Port 6543."

    /// The id of the summary entry the tests build.
    private static let entryId = "compaction-summary-role"

    /// The size before the compaction that the checkpoint of the test entry states.
    private static let checkpointTokensBefore = 2

    /// The size after the compaction that the checkpoint of the test entry states.
    private static let checkpointTokensAfter = 1

    /// A summary entry, as ``CompactionSegment/boundaryEntry(id:summaryText:content:)``
    /// builds it for an applied compaction.
    private static func summaryEntry() -> Transcript.Entry {
        CompactionSegment.boundaryEntry(
            id: entryId,
            summaryText: summary,
            content: CompactionSegment.Content(
                liveWindowEntryIds: [entryId], compactedEntryIds: ["prompt-1"],
                tokensBefore: checkpointTokensBefore, tokensAfter: checkpointTokensAfter,
                stagesApplied: [Summarization.stageName], promptName: CompactionPrompt.default.name))
    }

    @Test("the summary entry renders as a user message that starts with the header and holds the summary")
    func summaryRendersAsAUserMessage() throws {
        let instructions = Transcript.Entry.instructions(
            Transcript.Instructions(
                id: "instructions", segments: [.text(Transcript.TextSegment(content: "be brief"))],
                toolDefinitions: []))
        let question = Transcript.Entry.prompt(
            Transcript.Prompt(id: "question", segments: [.text(Transcript.TextSegment(content: "Which port?"))]))

        let messages = TranscriptChatMessages.messages(
            for: Transcript(entries: [instructions, Self.summaryEntry(), question]))

        #expect(messages.map { $0["role"] as? String } == ["system", "user", "user"])
        let content = try #require(messages[1]["content"] as? String)
        #expect(content == "\(CompactionSegment.summaryHeader)\n\(Self.summary)")
    }

    @Test("a cold transcript reads the summary entry as one compaction row whose summary has no header")
    func coldTranscriptReadsTheSummaryEntryAsACompactionRow() {
        let rows = SessionProjection.transcriptRows(from: [Self.summaryEntry()])

        guard case .compaction(let result)? = rows.first?.kind else {
            Issue.record("expected one compaction row")
            return
        }
        #expect(rows.count == 1)
        #expect(rows.first?.sourceEntryId == Self.entryId)
        #expect(result.summary == Self.summary)
        #expect(result.summaryEntryId == Self.entryId)
    }

    @Test("restating the sizes keeps the summary entry a prompt with the same segments of text")
    func restatingTheSizesKeepsThePrompt() throws {
        let restatedTokensBefore = 20
        let restatedTokensAfter = 10

        let restated = CompactionSegment.restatingSizes(
            of: Self.summaryEntry(), tokensBefore: restatedTokensBefore, tokensAfter: restatedTokensAfter)

        #expect(summaryEntryTexts(of: restated) == [CompactionSegment.summaryHeader, Self.summary])
        let content = try #require(try checkpointContent(of: restated))
        #expect(content.tokensBefore == restatedTokensBefore)
        #expect(content.tokensAfter == restatedTokensAfter)
    }
}
