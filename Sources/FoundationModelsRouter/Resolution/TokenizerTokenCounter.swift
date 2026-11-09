import Foundation
import FoundationModels
import FoundationModelsLlamaCpp
import MLXLMCommon

/// The live ``TokenCounter``: it counts with the tokenizer of a loaded model.
///
/// The counter holds the rules every backend shares: a text counts its tokens
/// with no special tokens added, a prefix keeps nothing for a limit of zero or
/// less and the whole text when it fits, and a transcript counts as the chat
/// template of the model renders it. Its ``CountingTokenizer`` reads the
/// vocabulary of the model: ``MLXCountingTokenizer`` for an MLX model, and the
/// `LlamaTokenizer` of a GGUF model.
struct TokenizerTokenCounter: TokenCounter {
    /// The tokenizer of the loaded model.
    private let tokenizer: any CountingTokenizer

    /// Creates a counter over `tokenizer`.
    ///
    /// - Parameter tokenizer: The tokenizer of the loaded model.
    init(tokenizer: any CountingTokenizer) {
        self.tokenizer = tokenizer
    }

    /// Creates a counter over the tokenizer of a loaded MLX model.
    ///
    /// - Parameter tokenizer: The tokenizer of the loaded model.
    init(tokenizer: any Tokenizer) {
        self.init(tokenizer: MLXCountingTokenizer(tokenizer: tokenizer))
    }

    /// The number of tokens `tokenizer` encodes `text` to, with no special
    /// tokens added.
    func count(_ text: String) -> Int {
        tokenizer.plainTextTokens(of: text).count
    }

    /// The number of tokens the chat template renders `transcript` to.
    ///
    /// - Throws: What the render of the chat template throws.
    func count(_ transcript: Transcript) throws -> Int {
        try tokenizer.renderedTokenCount(of: transcript)
    }

    /// The first `limit` tokens of `text`, decoded back to text.
    func prefix(of text: String, tokens limit: Int) -> String {
        guard limit > 0 else { return "" }
        let tokens = tokenizer.plainTextTokens(of: text)
        guard tokens.count > limit else { return text }
        return tokenizer.leadingText(of: text, tokens: tokens, limit: limit)
    }
}

/// A tokenizer a ``TokenizerTokenCounter`` counts with: the vocabulary and the
/// chat template of one loaded model.
protocol CountingTokenizer: Sendable {
    /// The tokens of `text`, with no special tokens added. Content inside a
    /// conversation carries no sequence markers of its own.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The tokens.
    func plainTextTokens(of text: String) -> [Int]

    /// The text of the first `limit` tokens of `text`. The counter asks only
    /// for a cut: `limit` is more than zero and less than `tokens.count`.
    ///
    /// - Parameters:
    ///   - text: The text to cut.
    ///   - tokens: The tokens of `text` (``plainTextTokens(of:)``).
    ///   - limit: The number of tokens to keep.
    /// - Returns: The kept text.
    func leadingText(of text: String, tokens: [Int], limit: Int) -> String

    /// The number of tokens the chat template of the model renders
    /// `transcript` to.
    ///
    /// - Parameter transcript: The transcript to render.
    /// - Returns: The count of the tokens of the rendered prompt.
    /// - Throws: What the render of the chat template throws.
    func renderedTokenCount(of transcript: Transcript) throws -> Int
}

/// The ``CountingTokenizer`` of an MLX model: its swift-transformers tokenizer.
///
/// A transcript is rendered through the chat template of the tokenizer, the
/// same way the MLX generation path renders it before a call: the
/// instructions entry is the system message, its tool definitions are the
/// tool specifications, and every later entry is one chat message (see
/// ``TranscriptChatMessages``). A tokenizer with no chat template renders the
/// messages as plain text, which is the fallback the MLX generation path
/// takes for such a model.
struct MLXCountingTokenizer: CountingTokenizer {
    /// The tokenizer of the loaded model.
    let tokenizer: any Tokenizer

    /// The tokens `tokenizer` encodes `text` to, with no special tokens added.
    func plainTextTokens(of text: String) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: false)
    }

    /// The first `limit` of `tokens`, decoded back to text.
    func leadingText(of text: String, tokens: [Int], limit: Int) -> String {
        tokenizer.decode(tokenIds: Array(tokens.prefix(limit)), skipSpecialTokens: false)
    }

    /// The number of tokens the chat template renders `transcript` to.
    ///
    /// - Throws: What the chat template throws, except a missing template,
    ///   which takes the plain-text fallback.
    func renderedTokenCount(of transcript: Transcript) throws -> Int {
        let messages = TranscriptChatMessages.messages(for: transcript)
        let tools = try TranscriptChatMessages.toolSpecifications(for: transcript)
        do {
            return try tokenizer.applyChatTemplate(
                messages: messages, tools: tools.isEmpty ? nil : tools, additionalContext: nil
            ).count
        } catch TokenizerError.missingChatTemplate {
            return tokenizer.encode(text: TranscriptChatMessages.plainText(of: messages), addSpecialTokens: true).count
        }
    }
}

/// The ``CountingTokenizer`` of a GGUF model: the vocabulary of the loaded
/// `LlamaLanguageModel`. Its own `renderedTokenCount(of:)` renders a
/// transcript through the chat template of the model, the same way the
/// llama.cpp generation path renders it before a call. Each call reads only
/// the vocabulary, so a count runs from any thread while the model generates.
extension LlamaTokenizer: CountingTokenizer {
    /// The tokens of `text`, with no special tokens added. The tokenizer
    /// throws only for a text of more than `Int32.max` bytes, which gives no
    /// tokens.
    func plainTextTokens(of text: String) -> [Int] {
        ((try? tokens(text)) ?? []).map(Int.init)
    }

    /// The text of the first `limit` tokens of `text`, cut by the tokenizer
    /// itself so the cut never falls inside a character. The tokenizer throws
    /// only for a text of more than `Int32.max` bytes, which keeps nothing.
    func leadingText(of text: String, tokens: [Int], limit: Int) -> String {
        (try? prefix(of: text, tokens: limit)) ?? ""
    }
}

/// Renders a `Transcript` to the chat messages the MLX generation path
/// renders it to, so a count and a generation read one conversation.
///
/// The rendering follows the MLX transcript converter entry for entry: the
/// instructions entry is the system message, a prompt is a user message, a
/// response is an assistant message, a tool-calls entry is an assistant
/// message that carries the calls, a tool output is a tool message that
/// answers its call by id, and a reasoning entry is not replayed.
enum TranscriptChatMessages {
    /// The raw chat messages of `transcript`, in order.
    ///
    /// - Parameter transcript: The transcript to render.
    /// - Returns: One message dictionary per rendered entry.
    static func messages(for transcript: Transcript) -> [Message] {
        DefaultMessageGenerator().generate(messages: transcript.compactMap(chatMessage))
    }

    /// The tool specifications the chat template renders for `transcript`:
    /// one function envelope per tool definition of the instructions entry.
    ///
    /// - Parameter transcript: The transcript to read the definitions from.
    /// - Returns: The specifications, in definition order.
    /// - Throws: When a parameter schema does not encode to a JSON object.
    static func toolSpecifications(for transcript: Transcript) throws -> [[String: any Sendable]] {
        try transcript.flatMap { entry -> [Transcript.ToolDefinition] in
            guard case .instructions(let instructions) = entry else { return [] }
            return instructions.toolDefinitions
        }.map(toolSpecification)
    }

    /// The plain-text form of `messages`: their contents, separated by a
    /// blank line. It is the rendering a tokenizer with no chat template gets.
    ///
    /// - Parameter messages: The raw chat messages.
    /// - Returns: The joined contents.
    static func plainText(of messages: [Message]) -> String {
        messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
    }

    /// The chat message of `entry`, or `nil` for an entry the model does not
    /// see again.
    private static func chatMessage(for entry: Transcript.Entry) -> Chat.Message? {
        switch entry {
        case .instructions(let instructions):
            return text(of: instructions.segments).map { Chat.Message.system($0) }
        case .prompt(let prompt):
            return text(of: prompt.segments).map { Chat.Message.user($0) }
        case .response(let response):
            return text(of: response.segments).map { Chat.Message.assistant($0) }
        case .toolCalls(let toolCalls):
            let calls = toolCalls.map(toolCall)
            return calls.isEmpty ? nil : Chat.Message.assistant("", toolCalls: calls)
        case .toolOutput(let output):
            return Chat.Message.tool(toolOutputContent(of: output.segments), id: output.id)
        case .reasoning, .data:
            return nil
        @unknown default:
            return nil
        }
    }

    /// The joined `.text` content of `segments`, or `nil` when they hold none.
    private static func text(of segments: [Transcript.Segment]) -> String? {
        let joined = Summarization.text(of: segments)
        return joined.isEmpty ? nil : joined
    }

    /// The content of a tool output: its `.text` segments, and its
    /// `.structure` segments as JSON, in order.
    private static func toolOutputContent(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }
            if case .structure(let structure) = segment { return structure.content.jsonString }
            return nil
        }.joined(separator: "\n")
    }

    /// The MLX tool call of `call`, with its arguments decoded from JSON.
    /// Arguments that do not decode render as none.
    private static func toolCall(_ call: Transcript.ToolCall) -> MLXLMCommon.ToolCall {
        let arguments =
            (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.jsonString.utf8))) ?? [:]
        return MLXLMCommon.ToolCall(function: .init(name: call.toolName, arguments: arguments), id: call.id)
    }

    /// The function envelope of `tool`, the shape every MLX chat template
    /// reads a tool specification in.
    private static func toolSpecification(_ tool: Transcript.ToolDefinition) throws -> [String: any Sendable] {
        let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))
        guard let parameters = parameters as? [String: any Sendable] else {
            throw TranscriptChatMessagesError.parameterSchemaIsNotAnObject(tool: tool.name)
        }
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }
}

/// A failure rendering a transcript to chat messages.
enum TranscriptChatMessagesError: Error, Equatable {
    /// A tool definition's parameter schema encoded to something other than
    /// a JSON object, so no tool specification can carry it.
    case parameterSchemaIsNotAnObject(tool: String)
}
