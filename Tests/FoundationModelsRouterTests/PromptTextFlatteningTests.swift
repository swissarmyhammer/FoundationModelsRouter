import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Pins ``TranscriptEntryMapper``'s `Transcript.Prompt` text-flattening
/// overload — the plain-text form ``RoutedSession/dispatchNextPrompt()`` hands
/// a backend for a queued prompt, since the backend's generation surface takes
/// a `String` rather than a `Transcript.Prompt`.
///
/// Every assertion here fixes a property that used to belong to a private copy
/// of the segment extraction inside `RoutedSessionActor`: the segments join
/// with *no* separator (unlike the recording-side overload, which joins with a
/// newline), non-text segments contribute nothing, and a prompt carrying no
/// `.text` segment flattens to `""` rather than to `nil`. Changing any one of
/// them changes what the model is actually asked.
@Suite("Prompt text flattening: a queued Transcript.Prompt to the string a backend is given")
struct PromptTextFlatteningTests {
    @Test("every .text segment's content joins in order with no separator between them")
    func textSegmentsJoinInOrderWithNoSeparator() {
        let prompt = Transcript.Prompt(segments: [
            .text(Transcript.TextSegment(content: "first line\n")),
            .text(Transcript.TextSegment(content: "second line")),
        ])

        // A separator of any kind — the recording side's "\n" in particular —
        // would land an extra character between the two contents.
        #expect(TranscriptEntryMapper.flattenedText(prompt) == "first line\nsecond line")
    }

    @Test("a non-text segment contributes nothing, and the text segments around it still join")
    func nonTextSegmentsAreSkipped() {
        let event = OperationEvent(
            tool: "shell", op: "run command", correlationID: "c1", kind: .completed, detail: "exit 0")
        let prompt = Transcript.Prompt(segments: [
            .text(Transcript.TextSegment(content: "alpha ")),
            .custom(OperationEventSegment(id: "seg-1", content: event)),
            .text(Transcript.TextSegment(content: "omega")),
        ])

        #expect(TranscriptEntryMapper.flattenedText(prompt) == "alpha omega")
    }

    @Test("a prompt carrying no .text segment at all flattens to the empty string")
    func promptWithoutTextSegmentsFlattensToEmptyString() {
        let event = OperationEvent(
            tool: "shell", op: "run command", correlationID: "c2", kind: .completed, detail: "exit 0")
        let customOnly = Transcript.Prompt(segments: [
            .custom(OperationEventSegment(id: "seg-2", content: event))
        ])

        #expect(TranscriptEntryMapper.flattenedText(Transcript.Prompt(segments: [])) == "")
        #expect(TranscriptEntryMapper.flattenedText(customOnly) == "")
    }

    @Test("the recording-side overload keeps its own newline join and nil-for-empty answer")
    func recordingSideFlatteningIsUnchanged() {
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "first line")),
                .text(Transcript.TextSegment(content: "second line")),
            ]))

        let (_, _, text) = TranscriptEntryMapper.event(from: entry)

        // Sharing one segment extraction with the prompt overload must not
        // pull the prompt overload's separator-less join onto this path.
        #expect(text == "first line\nsecond line")
        #expect(TranscriptEntryMapper.event(from: .toolCalls(Transcript.ToolCalls([]))).text == nil)
    }
}
