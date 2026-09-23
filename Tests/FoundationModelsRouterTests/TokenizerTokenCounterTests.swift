import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Proves ``TokenizerTokenCounter`` counts with the tokenizer it is given
/// (task ^xjk0pp8): text through `encode`, a prefix through `decode`, and a
/// transcript through the chat template with the instructions as the system
/// message and the tool definitions as the tool specifications.
///
/// Everything runs against a scripted tokenizer. No model, no download.
@Suite("TokenizerTokenCounter: the live counter counts with the model's tokenizer")
struct TokenizerTokenCounterTests {
    /// The text every text fixture counts: one non-ASCII scalar, so a byte
    /// count and a scalar count differ.
    private static let sampleText = "héllo world"

    /// The tokens the scripted tokenizer keeps in the prefix fixture.
    private static let prefixTokens = 4

    /// A transcript with every entry kind the model reads again, and one it
    /// does not: instructions with tool definitions, a prompt, a tool call
    /// with its output, a reasoning entry and a response.
    private static func makeTranscript() throws -> Transcript {
        let instructions = Transcript.Entry.instructions(
            Transcript.Instructions(
                id: "instructions",
                segments: [.text(Transcript.TextSegment(id: "instructions-text", content: "be brief"))],
                toolDefinitions: FixedToolSurface.toolDefinitions
            )
        )
        let reasoning = Transcript.Entry.reasoning(
            Transcript.Reasoning(
                id: "reasoning",
                segments: [.text(Transcript.TextSegment(id: "reasoning-text", content: "private thought"))],
                signature: nil
            )
        )
        let turn = try TranscriptFixtures.makeTurn(index: 1, toolOutputText: "tool result")
        return Transcript(entries: [instructions] + turn.dropLast() + [reasoning, turn[turn.count - 1]])
    }

    @Test("count(text) is the number of tokens the tokenizer encodes, with no special tokens")
    func textCountIsTheEncodedLength() {
        let counter = TokenizerTokenCounter(tokenizer: ScriptedChatTokenizer(hasChatTemplate: true))

        #expect(counter.count(Self.sampleText) == Self.sampleText.unicodeScalars.count)
    }

    @Test("prefix(of:tokens:) keeps the first tokens, decoded back to text")
    func prefixKeepsTheFirstTokens() {
        let counter = TokenizerTokenCounter(tokenizer: ScriptedChatTokenizer(hasChatTemplate: true))

        let kept = counter.prefix(of: Self.sampleText, tokens: Self.prefixTokens)

        #expect(kept == String(Self.sampleText.prefix(Self.prefixTokens)))
        #expect(counter.count(kept) == Self.prefixTokens)
    }

    @Test("prefix(of:tokens:) returns the text unchanged when it holds at most the limit")
    func prefixLeavesShortTextUnchanged() {
        let counter = TokenizerTokenCounter(tokenizer: ScriptedChatTokenizer(hasChatTemplate: true))

        #expect(counter.prefix(of: Self.sampleText, tokens: counter.count(Self.sampleText)) == Self.sampleText)
    }

    @Test("prefix(of:tokens:) keeps nothing for a limit of zero")
    func prefixKeepsNothingForZero() {
        let counter = TokenizerTokenCounter(tokenizer: ScriptedChatTokenizer(hasChatTemplate: true))

        #expect(counter.prefix(of: Self.sampleText, tokens: 0) == "")
    }

    @Test("count(transcript) renders the transcript through the chat template: instructions, prompt, tool call, tool output and response, with the tool definitions as specifications")
    func transcriptCountRendersThroughTheChatTemplate() throws {
        let tokenizer = ScriptedChatTokenizer(hasChatTemplate: true)
        let counter = TokenizerTokenCounter(tokenizer: tokenizer)
        let transcript = try Self.makeTranscript()

        let counted = try counter.count(transcript)

        let render = try #require(tokenizer.receivedRenders.first)
        let roles = render.messages.map { $0["role"] as? String }
        #expect(roles == ["system", "user", "assistant", "tool", "assistant"])
        #expect(render.messages[0]["content"] as? String == "be brief")
        #expect(render.messages[1]["content"] as? String == "question")
        #expect(render.messages[2]["tool_calls"] != nil)
        #expect(render.messages[3]["content"] as? String == "tool result")
        #expect(render.messages[3]["tool_call_id"] as? String == "toolOutput-1")
        #expect(render.messages[4]["content"] as? String == "answer")

        let tools = try #require(render.tools)
        #expect(tools.count == FixedToolSurface.toolDefinitions.count)
        let functions = tools.compactMap { $0["function"] as? [String: any Sendable] }
        #expect(functions.map { $0["name"] as? String } == FixedToolSurface.toolDefinitions.map { $0.name })
        #expect(functions.allSatisfy { $0["parameters"] is [String: any Sendable] })

        let expectedTokens =
            tokenizer.encode(text: ScriptedChatTokenizer.renderedText(of: render.messages), addSpecialTokens: false)
            .count + tools.count
        #expect(counted == expectedTokens)
    }

    @Test("count(transcript) does not replay a reasoning entry")
    func transcriptCountSkipsReasoning() throws {
        let tokenizer = ScriptedChatTokenizer(hasChatTemplate: true)
        let counter = TokenizerTokenCounter(tokenizer: tokenizer)

        _ = try counter.count(try Self.makeTranscript())

        let render = try #require(tokenizer.receivedRenders.first)
        let contents = render.messages.compactMap { $0["content"] as? String }
        #expect(!contents.contains("private thought"))
    }

    @Test("count(transcript) gives no tool specifications for a transcript with no tool definitions")
    func transcriptCountGivesNoToolsWithoutDefinitions() throws {
        let tokenizer = ScriptedChatTokenizer(hasChatTemplate: true)
        let counter = TokenizerTokenCounter(tokenizer: tokenizer)
        let transcript = Transcript(entries: [TranscriptFixtures.makeInstructions()] + (try TranscriptFixtures.makeTurn(index: 1)))

        _ = try counter.count(transcript)

        let render = try #require(tokenizer.receivedRenders.first)
        #expect(render.tools == nil)
    }

    @Test("count(transcript) falls back to the plain-text rendering when the tokenizer has no chat template")
    func transcriptCountFallsBackToPlainText() throws {
        let tokenizer = ScriptedChatTokenizer(hasChatTemplate: false)
        let counter = TokenizerTokenCounter(tokenizer: tokenizer)
        let transcript = try Self.makeTranscript()

        let counted = try counter.count(transcript)

        let plainText = TranscriptChatMessages.plainText(of: TranscriptChatMessages.messages(for: transcript))
        #expect(counted == tokenizer.encode(text: plainText, addSpecialTokens: true).count)
        #expect(plainText.contains("be brief"))
        #expect(plainText.contains("tool result"))
        #expect(tokenizer.receivedRenders.isEmpty)
    }
}
