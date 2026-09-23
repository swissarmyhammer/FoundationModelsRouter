import Foundation
import MLXLMCommon
import Synchronization

/// A tokenizer with a rule of its own: one id per Unicode scalar, and a chat
/// template that renders each message as one `role: content` line.
///
/// A test that needs a model's tokenizer uses it. No model, no download.
///
/// The class is `Sendable` because each stored property is an immutable
/// `Sendable` value, and `renders` is a `Mutex`.
final class ScriptedChatTokenizer: Tokenizer, Sendable {
    /// One chat-template render the tokenizer received.
    struct Render: Sendable {
        /// The raw messages, in order.
        let messages: [Message]

        /// The tool specifications, or `nil` when the call gave none.
        let tools: [[String: any Sendable]]?
    }

    /// The failure of a template that requires a user message.
    enum TemplateError: Error, Equatable {
        /// The messages hold no message with the `user` role. The Qwen3.8
        /// template states it as "No user query found in messages."
        case noUserMessage
    }

    /// Whether the tokenizer has a chat template. Without one every render
    /// throws `TokenizerError.missingChatTemplate`.
    private let hasChatTemplate: Bool

    /// Whether the template refuses messages that hold no user message, as
    /// the Qwen3.8 and Llama-3.2 templates do.
    private let requiresUserMessage: Bool

    /// The renders received so far, in order.
    private let renders = Mutex<[Render]>([])

    /// The id of the beginning-of-sequence token. The NUL scalar never
    /// appears in the fixtures, so the id never collides with content.
    private static let bosId = 0

    /// The id of every tool specification in a render.
    private static let toolMarkerId = 1

    /// The role of a user message in a raw chat message.
    private static let userRole = "user"

    /// Creates the tokenizer.
    ///
    /// - Parameters:
    ///   - hasChatTemplate: Whether the tokenizer has a chat template.
    ///   - requiresUserMessage: Whether the template refuses messages that
    ///     hold no user message.
    init(hasChatTemplate: Bool = true, requiresUserMessage: Bool = false) {
        self.hasChatTemplate = hasChatTemplate
        self.requiresUserMessage = requiresUserMessage
    }

    /// The renders received so far, in order.
    var receivedRenders: [Render] {
        renders.withLock { $0 }
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        let scalars = text.unicodeScalars.map { Int($0.value) }
        return addSpecialTokens ? [Self.bosId] + scalars : scalars
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        let content = tokenIds.filter { !skipSpecialTokens || $0 != Self.bosId }
        return String(String.UnicodeScalarView(content.compactMap { Unicode.Scalar(UInt32($0)) }))
    }

    func convertTokenToId(_ token: String) -> Int? {
        token == bosToken ? Self.bosId : nil
    }

    func convertIdToToken(_ id: Int) -> String? {
        id == Self.bosId ? bosToken : nil
    }

    var bosToken: String? { "<s>" }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        guard hasChatTemplate else { throw TokenizerError.missingChatTemplate }
        renders.withLock { $0.append(Render(messages: messages, tools: tools)) }
        guard !requiresUserMessage || messages.contains(where: { $0["role"] as? String == Self.userRole }) else {
            throw TemplateError.noUserMessage
        }
        let toolMarkers = Array(repeating: Self.toolMarkerId, count: tools?.count ?? 0)
        return encode(text: Self.renderedText(of: messages), addSpecialTokens: false) + toolMarkers
    }

    /// The text the template renders `messages` to: one `role: content` line
    /// per message.
    ///
    /// - Parameter messages: The raw chat messages.
    /// - Returns: The rendered text.
    static func renderedText(of messages: [Message]) -> String {
        messages.map { "\($0["role"] as? String ?? ""): \($0["content"] as? String ?? "")" }
            .joined(separator: "\n")
    }
}
