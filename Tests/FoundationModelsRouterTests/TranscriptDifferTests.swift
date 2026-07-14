import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Tests for ``TranscriptDiffer``, the standalone last-seen-vs-current
/// `Transcript` diff engine extracted from ``RoutedSessionActor``'s
/// recorder-bracketed generate chokepoint.
///
/// The differ takes two `FoundationModels.Transcript` snapshots plus a
/// session's identity (`routerId`, `sessionId`, `parentId`, `slot`, `model`)
/// and returns the ordered ``TranscriptEvent/Partial`` values every entry
/// `current` gained beyond `lastSeen` maps to, via the existing
/// ``TranscriptEntryMapper``. It is the one diff implementation
/// ``RoutedSessionActor`` and the upcoming recording handle both share.
@Suite("TranscriptDiffer: last-seen-vs-current Transcript diff")
struct TranscriptDifferTests {
    // MARK: - Identity fixture

    private struct Identity {
        let routerId = ULID.generate()
        let sessionId = ULID.generate()
        let parentId: ULID?
        let slot = ModelSlot.standard
        let model = ModelRef("org/repo@rev")

        /// - Parameter parentId: A fresh generated id by default (a forked
        ///   session), or `nil` to represent a root session.
        init(parentId: ULID? = ULID.generate()) {
            self.parentId = parentId
        }
    }

    private func diff(
        lastSeen: [Transcript.Entry],
        current: [Transcript.Entry],
        identity: Identity = Identity()
    ) -> [TranscriptEvent.Partial] {
        TranscriptDiffer.diff(
            lastSeen: Transcript(entries: lastSeen),
            current: Transcript(entries: current),
            routerId: identity.routerId,
            sessionId: identity.sessionId,
            parentId: identity.parentId,
            slot: identity.slot,
            model: identity.model
        )
    }

    // MARK: - Sample entries

    private static func instructionsEntry(id: String = "instr-1") -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: id,
                segments: [.text(Transcript.TextSegment(id: "\(id)-s1", content: "you are a helpful assistant"))],
                toolDefinitions: []
            )
        )
    }

    private static func promptEntry(id: String = "prompt-1", text: String = "hello") -> Transcript.Entry {
        .prompt(
            Transcript.Prompt(
                id: id,
                segments: [.text(Transcript.TextSegment(id: "\(id)-s1", content: text))],
                options: GenerationOptions()
            )
        )
    }

    private static func responseEntry(id: String = "response-1", text: String = "hi there") -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: id,
                segments: [.text(Transcript.TextSegment(id: "\(id)-s1", content: text))]
            )
        )
    }

    private static func reasoningEntry(id: String = "reasoning-1") -> Transcript.Entry {
        .reasoning(
            Transcript.Reasoning(
                id: id,
                segments: [.text(Transcript.TextSegment(id: "\(id)-s1", content: "thinking it through"))],
                signature: nil
            )
        )
    }

    private static func toolCallsEntry(id: String = "calls-1") -> Transcript.Entry {
        .toolCalls(
            Transcript.ToolCalls(
                id: id,
                [
                    Transcript.ToolCall(
                        id: "call-1",
                        toolName: "search",
                        arguments: (try? GeneratedContent(json: #"{"query":"weather"}"#)) ?? GeneratedContent("")
                    )
                ]
            )
        )
    }

    private static func toolOutputEntry(id: String = "output-1") -> Transcript.Entry {
        .toolOutput(
            Transcript.ToolOutput(
                id: id,
                toolName: "search",
                segments: [.text(Transcript.TextSegment(id: "\(id)-s1", content: "sunny, 72F"))]
            )
        )
    }

    // MARK: - Tests

    @Test("empty lastSeen to instructions+prompt emits both, in order")
    func emptyToInstructionsAndPrompt() {
        let instructions = Self.instructionsEntry()
        let prompt = Self.promptEntry()
        let result = diff(lastSeen: [], current: [instructions, prompt])

        #expect(result.map(\.kind) == [.instructions, .prompt])
        #expect(result[0].text == "you are a helpful assistant")
        #expect(result[0].entry != nil)
        #expect(result[1].text == "hello")
        #expect(result[1].entry != nil)
    }

    @Test("prompt to response emits only the new response entry")
    func promptToResponse() {
        let prompt = Self.promptEntry()
        let response = Self.responseEntry()
        let result = diff(lastSeen: [prompt], current: [prompt, response])

        #expect(result.map(\.kind) == [.response])
        #expect(result[0].text == "hi there")
        #expect(result[0].entry != nil)
    }

    @Test("a tool-using turn emits toolCalls, then toolOutput, then response, in order")
    func toolUsingTurn() {
        let prompt = Self.promptEntry()
        let toolCalls = Self.toolCallsEntry()
        let toolOutput = Self.toolOutputEntry()
        let response = Self.responseEntry()
        let result = diff(
            lastSeen: [prompt],
            current: [prompt, toolCalls, toolOutput, response]
        )

        #expect(result.map(\.kind) == [.toolCalls, .toolOutput, .response])
        // .toolCalls carries no flattened text (no .text segments).
        #expect(result[0].text == nil)
        #expect(result[0].entry != nil)
        #expect(result[1].text == "sunny, 72F")
        #expect(result[1].entry != nil)
        #expect(result[2].text == "hi there")
        #expect(result[2].entry != nil)
    }

    @Test("reasoning entries are diffed and mapped like every other kind")
    func reasoningEntryDiffed() {
        let prompt = Self.promptEntry()
        let reasoning = Self.reasoningEntry()
        let result = diff(lastSeen: [prompt], current: [prompt, reasoning])

        #expect(result.map(\.kind) == [.reasoning])
        #expect(result[0].text == "thinking it through")
        #expect(result[0].entry != nil)
    }

    @Test("identical transcripts produce an empty diff")
    func identicalTranscriptsProduceEmptyDiff() {
        let prompt = Self.promptEntry()
        let response = Self.responseEntry()
        let result = diff(lastSeen: [prompt, response], current: [prompt, response])

        #expect(result.isEmpty)
    }

    @Test("an empty-to-empty diff produces an empty diff")
    func emptyToEmptyProducesEmptyDiff() {
        let result = diff(lastSeen: [], current: [])
        #expect(result.isEmpty)
    }

    @Test("a current shorter than lastSeen (a shrink) safely produces an empty diff rather than trapping")
    func shrunkenCurrentProducesEmptyDiff() {
        let prompt = Self.promptEntry()
        let response = Self.responseEntry()

        // current has fewer entries than lastSeen: the defensive
        // `min(lastSeen.count, current.count)` clamp this type's doc comment
        // promises must kick in here, since a bare `current[lastSeen.count...]`
        // would be an out-of-bounds slice and trap.
        let droppedToEmpty = diff(lastSeen: [prompt, response], current: [])
        #expect(droppedToEmpty.isEmpty)

        let droppedByOne = diff(lastSeen: [prompt, response], current: [prompt])
        #expect(droppedByOne.isEmpty)
    }

    @Test("every produced partial carries the given session identity")
    func partialsCarrySessionIdentity() {
        let identity = Identity()
        let prompt = Self.promptEntry()
        let result = diff(lastSeen: [], current: [prompt], identity: identity)

        let partial = try! #require(result.first)
        #expect(partial.routerId == identity.routerId)
        #expect(partial.sessionId == identity.sessionId)
        #expect(partial.parentId == identity.parentId)
        #expect(partial.slot == identity.slot)
        #expect(partial.model == identity.model)
    }

    @Test("a nil parentId (a root session) is passed through as nil, not substituted")
    func nilParentIdPassesThrough() {
        let rootIdentity = Identity(parentId: nil)
        let prompt = Self.promptEntry()
        let result = diff(lastSeen: [], current: [prompt], identity: rootIdentity)

        let partial = try! #require(result.first)
        #expect(partial.parentId == nil)
    }

    @Test("ordering is stable across repeated diffs of the same inputs")
    func orderingIsStable() {
        let instructions = Self.instructionsEntry()
        let prompt = Self.promptEntry()
        let toolCalls = Self.toolCallsEntry()
        let toolOutput = Self.toolOutputEntry()
        let response = Self.responseEntry()
        let current = [instructions, prompt, toolCalls, toolOutput, response]
        let identity = Identity()

        let firstRun = diff(lastSeen: [], current: current, identity: identity)
        let secondRun = diff(lastSeen: [], current: current, identity: identity)

        #expect(firstRun.map(\.kind) == secondRun.map(\.kind))
        #expect(firstRun.map(\.kind) == [.instructions, .prompt, .toolCalls, .toolOutput, .response])
        #expect(firstRun == secondRun)
    }
}
