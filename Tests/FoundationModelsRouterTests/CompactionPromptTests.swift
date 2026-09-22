import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``CompactionPrompt/default`` and the segment flattening the
/// compaction renders each entry with.
@Suite("CompactionPrompt.default and segment flattening")
struct CompactionPromptTests {
    @Test("CompactionPrompt.default has its name and its eight sections")
    func defaultPromptNameAndSections() {
        let prompt = CompactionPrompt.default
        #expect(prompt.name == "router-default-v5")

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

    @Test("CompactionPrompt.default gives a bare stated fact its own section, so a summary states what a fact was")
    func defaultPromptKeepsBareStatedFacts() {
        // A gated eval measured a summary that recorded THAT a fact was
        // stated and dropped WHAT it was. A bare stated fact is in none of
        // the other seven sections.
        let text = CompactionPrompt.default.text
        #expect(text.contains("2. Stated facts — every concrete fact stated in the conversation, each with"))
        #expect(text.contains("Record WHAT was stated, never merely THAT something was stated"))
        #expect(text.contains("Never replace a stated value with a description of it."))
    }

    @Test("CompactionPrompt.default states the size budget as an aim, and demands values copied exactly")
    func defaultPromptStatesTheBudgetAndDemandsVerbatimValues() {
        let text = CompactionPrompt.default.text
        #expect(text.contains("size budget"))
        // The budget must be an aim. A reasoning model that counts its draft
        // against the size spends its whole ceiling on the count.
        #expect(text.contains("without counting"))
        #expect(text.contains("EXACTLY as it"))
        #expect(text.contains("character for character"))
    }

    @Test("CompactionPrompt.default quotes no fact of its own, so a model cannot copy an example into the summary")
    func defaultPromptQuotesNoExampleFact() {
        // A real 1B model wrote a quoted example out of the instructions in
        // place of a summary. The instructions now quote nothing.
        let text = CompactionPrompt.default.text
        #expect(text.contains("\"") == false)
        #expect(text.contains("never copy a phrase out of them"))
        #expect(text.contains("never write a line you have already written"))
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
