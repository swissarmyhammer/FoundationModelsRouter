import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The output of a recap call (D206): the recap is one line of at most 200
/// characters with no quotes, and it ends at the end of a word. An empty
/// output gives no recap.
@Suite("SessionRecapOutput: the text of a recap from the output of the model")
struct SessionRecapOutputTests {
    /// One sentence that a test repeats to make a long output.
    private static let sentence = "Fixed the parser tests and the build passes now "

    /// The number of times ``sentence`` repeats in an output of more than
    /// 400 characters.
    private static let repeatCount = 9

    /// An output of more than 400 characters.
    private static var longOutput: String {
        String(repeating: sentence, count: repeatCount)
    }

    /// The production change that makes this test fail: a recap that keeps
    /// the whole output of the model.
    @Test("an output of more than 400 characters gives a recap of at most 200 characters")
    func aLongOutputGivesAtMost200Characters() throws {
        let recap = try #require(SessionRecapOutput.recap(from: Self.longOutput))

        #expect(recap.count <= SessionRecapOutput.characterLimit)
    }

    /// The production change that makes this test fail: a cut at 200
    /// characters that cuts a word in two.
    @Test("the recap of a long output ends at the end of a word")
    func theRecapOfALongOutputEndsAtAWord() throws {
        let recap = try #require(SessionRecapOutput.recap(from: Self.longOutput))

        #expect(Self.longOutput.hasPrefix(recap + " "))
    }

    /// The production change that makes this test fail: a recap that keeps
    /// the quotes and the line breaks of the output.
    @Test("the recap has no quotes and no line breaks")
    func theRecapHasNoQuotesAndNoLineBreaks() {
        let recap = SessionRecapOutput.recap(from: "\"Fixed the build.\nThe tests pass.\"\n")

        #expect(recap == "Fixed the build. The tests pass.")
    }

    /// The production change that makes this test fail: an output with only
    /// quotes and white space that gives an empty recap.
    @Test("an output with no words gives no recap")
    func anOutputWithNoWordsGivesNoRecap() {
        #expect(SessionRecapOutput.recap(from: " \n\"\" ") == nil)
    }
}

/// The input of a recap call (D206): the previous recap, the user prompts
/// since the last recap (each cut to 500 characters), the tool calls of those
/// turns, and the last final message (cut to 2,000 characters), in at most
/// 4,000 tokens. The oldest prompts go first when the input is too long.
///
/// The counter is the scripted counter of the tests: one token for each
/// character.
@Suite("SessionRecapInput: the input of a recap call")
struct SessionRecapInputTests {
    /// The counter of each test: one token for each character.
    private static let counter = CharacterTokenCounter()

    /// A prompt longer than the limit of one prompt.
    private static let promptLength = 600

    /// A last message longer than the limit of the last message.
    private static let messageLength = 2_500

    /// The number of prompts of the input that is too long: each one at the
    /// limit of one prompt, so together they hold more than the token limit.
    private static let manyPromptCount = 10

    /// The prompt text of `input`.
    ///
    /// - Parameter input: The input.
    /// - Returns: The prompt of the recap call.
    private static func render(_ input: SessionRecapInput) -> String {
        input.prompt(countingWith: counter)
    }

    /// A prompt of `length` characters that starts with `marker`.
    ///
    /// - Parameters:
    ///   - marker: The first characters of the prompt.
    ///   - length: The length of the prompt.
    /// - Returns: The prompt.
    private static func prompt(_ marker: String, length: Int) -> String {
        marker + String(repeating: "x", count: length - marker.count)
    }

    /// The production changes that make this test fail: an input that keeps
    /// each prompt whole, and an input that keeps less than the first 500
    /// characters of a prompt (also none).
    @Test("each user prompt is cut to its first 500 characters")
    func eachPromptIsCutTo500Characters() {
        let long = String(repeating: "a", count: Self.promptLength)

        let rendered = Self.render(
            SessionRecapInput(previousRecap: nil, prompts: [long], toolCalls: [], lastMessage: nil))

        #expect(
            rendered.contains(String(repeating: "a", count: SessionRecapInput.promptCharacterLimit))
                && !rendered.contains(String(repeating: "a", count: SessionRecapInput.promptCharacterLimit + 1)))
    }

    /// The production changes that make this test fail: an input that keeps
    /// the last message whole, and an input that keeps less than the first
    /// 2,000 characters of the message (also an empty message).
    @Test("the last message is cut to its first 2,000 characters")
    func theLastMessageIsCutTo2000Characters() {
        let long = String(repeating: "m", count: Self.messageLength)

        let rendered = Self.render(SessionRecapInput(previousRecap: nil, prompts: [], toolCalls: [], lastMessage: long))

        #expect(
            rendered.contains(String(repeating: "m", count: SessionRecapInput.lastMessageCharacterLimit))
                && !rendered.contains(String(repeating: "m", count: SessionRecapInput.lastMessageCharacterLimit + 1)))
    }

    /// The production change that makes this test fail: an input with no
    /// token limit.
    @Test("an input of too many prompts holds at most 4,000 tokens")
    func anInputOfTooManyPromptsHoldsAtMostTheTokenLimit() {
        let prompts = (0..<Self.manyPromptCount).map {
            Self.prompt("prompt-\($0)", length: SessionRecapInput.promptCharacterLimit)
        }

        let rendered = Self.render(
            SessionRecapInput(previousRecap: nil, prompts: prompts, toolCalls: [], lastMessage: nil))

        #expect(Self.counter.count(rendered) <= SessionRecapInput.tokenLimit)
    }

    /// The production change that makes this test fail: a cut that drops
    /// the newest prompts first.
    @Test("an input that is too long drops the oldest prompts first")
    func anInputThatIsTooLongDropsTheOldestPromptsFirst() {
        let prompts = (0..<Self.manyPromptCount).map {
            Self.prompt("prompt-\($0)-", length: SessionRecapInput.promptCharacterLimit)
        }

        let rendered = Self.render(
            SessionRecapInput(previousRecap: nil, prompts: prompts, toolCalls: [], lastMessage: nil))

        #expect(rendered.contains("prompt-0-") == false && rendered.contains("prompt-\(Self.manyPromptCount - 1)-"))
    }

    /// The production change that makes this test fail: an input with no
    /// previous recap.
    @Test("the input holds the previous recap")
    func theInputHoldsThePreviousRecap() {
        let recap = "Fixed the login test; the build is green."

        let rendered = Self.render(
            SessionRecapInput(previousRecap: recap, prompts: [], toolCalls: [], lastMessage: nil))

        #expect(rendered.contains(recap))
    }

    /// The production change that makes this test fail: a tool call line
    /// with only the name of the tool.
    @Test("a tool call line names the tool and the path in its arguments")
    func aToolCallLineNamesTheToolAndThePath() {
        let line = SessionRecapInput.toolCallLine(
            name: "edit", argumentsJSON: #"{"text":"let x = 1","path":"Sources/App/main.swift"}"#)

        #expect(line == "edit Sources/App/main.swift")
    }

    /// The production change that makes this test fail: a tool call line
    /// that gives arguments with no target as text.
    @Test("a tool call line with no target in its arguments is the name of the tool")
    func aToolCallLineWithNoTargetIsTheName() {
        #expect(SessionRecapInput.toolCallLine(name: "list", argumentsJSON: #"{"limit":3}"#) == "list")
    }
}
