import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``CompactionPrompt/default`` and the segment flattening the
/// compaction renders each entry with.
@Suite("CompactionPrompt.default and segment flattening")
struct CompactionPromptTests {
    @Test("CompactionPrompt.default has its name and asks for the few points that matter to go on")
    func defaultPromptNameAndPoints() {
        let prompt = CompactionPrompt.default
        #expect(prompt.name == "router-default-v6")

        let text = prompt.text
        #expect(
            text.hasPrefix(
                "Summarize the conversation above. Whoever continues has no other memory of it.\n"
                    + "Write a short summary of the few points that matter to go on:\n"
            ))
        for point in [
            "- what the user wants;",
            "- what is decided, and what must not be done;",
            "- what is done, and what comes next;",
            "- any value the next step needs (a name, a path, a number), written exactly.",
        ] {
            #expect(text.contains(point))
        }
    }

    @Test("CompactionPrompt.default leaves out small talk and does not ask for a list of facts")
    func defaultPromptLeavesOutSmallTalkAndFactLists() {
        // The owner replaced the fact-counting sections of v5: a reasoning
        // model spent its whole allowed size on them and wrote no summary.
        let text = CompactionPrompt.default.text
        #expect(text.hasSuffix("Do not list facts for their own sake."))
        #expect(text.contains("Leave out small talk, and finished work that does not matter next."))
        #expect(text.contains("Stated facts") == false)
    }

    @Test("the assembled prompt puts the conversation above the instructions, the size budget and the framing")
    func assembledPromptPutsTheConversationFirst() {
        let content = "User: the conversation"
        let allowedSummaryTokens = 42
        let assembled = Summarization.assembledPrompt(
            .default, allowedSummaryTokens: allowedSummaryTokens, content: content)
        #expect(assembled.hasPrefix("\(content)\n\n---\n\n\(CompactionPrompt.default.text)\n\n"))
        #expect(assembled.contains("Size budget: about \(allowedSummaryTokens) tokens."))
        #expect(assembled.hasSuffix(Summarization.contentFramingDirective))
        #expect(Summarization.contentFramingDirective.hasPrefix("Everything before the line of three dashes"))
    }

    @Test("flattening an entry's segments joins every text segment in order with a newline and drops the other segments")
    func flatteningJoinsTextSegmentsAndDropsTheRest() throws {
        let structureContent = try GeneratedContent(json: #"{"tempF":72}"#)
        let segments: [Transcript.Segment] = [
            .text(Transcript.TextSegment(id: "s-1", content: "first line")),
            .structure(Transcript.StructuredSegment(id: "s-2", schemaName: "Weather", content: structureContent)),
            .text(Transcript.TextSegment(id: "s-3", content: "second line")),
        ]

        #expect(Summarization.text(of: segments) == "first line\nsecond line")
    }
}
