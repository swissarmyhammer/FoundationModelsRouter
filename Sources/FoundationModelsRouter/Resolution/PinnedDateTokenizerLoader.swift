import Foundation
import MLXLMCommon

/// A ``MLXLMCommon/TokenizerLoader`` that pins the calendar date a chat
/// template writes into its prompt.
///
/// ## Why this exists
///
/// A chat template can read the clock. The Llama 3.2 family writes
/// `Today Date: <today>` into the system header of every call, and it takes
/// that date from the template function `strftime_now`, which the Jinja engine
/// answers from `Date()` and the local time zone.
///
/// Greedy decoding pins the SAMPLING. It does not pin the PROMPT. So a
/// generation whose prompt carries the date answers differently on two calendar
/// days, from identical code and identical weights. A real-model test that
/// asserts on the text a model wrote is red on some days and green on others,
/// and a red run then states nothing about the change under test.
///
/// This loader closes that hole for the callers that need it. It wraps another
/// loader, and it wraps the tokenizer that loader vends, so every chat-template
/// render made through the loaded model states ``dateStringTemplateKey``. The
/// Llama family's template reads that variable FIRST and calls `strftime_now`
/// only when nothing defines it, so a stated date keeps the clock out of the
/// prompt.
///
/// ## What it does not do
///
/// It pins one template variable, and it is opt-in. An application that wants
/// the model to know today's date loads without it, which is the default
/// everywhere in this package. A template that reads the clock through some
/// other variable is not covered; ``dateStringTemplateKey`` is the name the
/// Llama family uses.
public struct PinnedDateTokenizerLoader: TokenizerLoader {
    /// The chat-template variable that carries the date.
    ///
    /// The name the Llama 3.1 and 3.2 templates read, and the name their
    /// `strftime_now` fallback assigns to.
    public static let dateStringTemplateKey = "date_string"

    /// The loader that reads the real tokenizer from disk.
    private let base: any TokenizerLoader

    /// The date every chat-template render is given.
    private let dateString: String

    /// Creates a loader that pins the date over another loader.
    ///
    /// - Parameters:
    ///   - base: the loader that reads the real tokenizer.
    ///   - dateString: the date to state, written the way the template writes
    ///     it. The Llama family formats it `%d %b %Y`, so `26 Jul 2024` is the
    ///     shape a template renders.
    public init(wrapping base: any TokenizerLoader, dateString: String) {
        self.base = base
        self.dateString = dateString
    }

    /// Loads the real tokenizer and wraps it so its chat-template renders carry
    /// the pinned date.
    ///
    /// - Parameter directory: the directory the real tokenizer is read from.
    /// - Returns: the wrapped tokenizer.
    /// - Throws: whatever the wrapped loader throws.
    public func load(from directory: URL) async throws -> any Tokenizer {
        PinnedDateTokenizer(
            wrapping: try await base.load(from: directory), dateString: dateString)
    }
}

/// The tokenizer ``PinnedDateTokenizerLoader`` vends.
///
/// It states ``PinnedDateTokenizerLoader/dateStringTemplateKey`` on every
/// chat-template render, and forwards every other operation to the tokenizer it
/// wraps.
///
/// The date is stated only when the CALL states none of its own. A caller that
/// named the date already has a prompt that does not move, which is the whole
/// point, and overwriting it would take a decision away from that caller.
struct PinnedDateTokenizer: Tokenizer {
    /// The tokenizer that holds the vocabulary and the chat template.
    private let base: any Tokenizer

    /// The date every chat-template render is given.
    private let dateString: String

    /// Creates the wrapper.
    ///
    /// - Parameters:
    ///   - base: the tokenizer to wrap.
    ///   - dateString: the date to state.
    init(wrapping base: any Tokenizer, dateString: String) {
        self.base = base
        self.dateString = dateString
    }

    /// The chat-template context a render is given, with the pinned date added.
    ///
    /// - Parameter additionalContext: the template variables the call stated.
    /// - Returns: those variables, plus the pinned date when the call stated no
    ///   date of its own.
    private func pinningDate(
        in additionalContext: [String: any Sendable]?
    ) -> [String: any Sendable] {
        var pinned = additionalContext ?? [:]
        let key = PinnedDateTokenizerLoader.dateStringTemplateKey
        if pinned[key] == nil {
            pinned[key] = dateString
        }
        return pinned
    }

    /// Forwards to the wrapped tokenizer.
    /// - Parameters:
    ///   - text: the text to tokenize.
    ///   - addSpecialTokens: whether to add the tokenizer's special tokens.
    /// - Returns: the token IDs representing the text.
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    /// Forwards to the wrapped tokenizer.
    /// - Parameters:
    ///   - tokenIds: the token IDs to decode.
    ///   - skipSpecialTokens: whether to omit special tokens.
    /// - Returns: the decoded text.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    /// Forwards to the wrapped tokenizer.
    /// - Parameter token: the token text.
    /// - Returns: the token's ID, or `nil` when the token is unknown.
    func convertTokenToId(_ token: String) -> Int? {
        base.convertTokenToId(token)
    }

    /// Forwards to the wrapped tokenizer.
    /// - Parameter id: the token ID.
    /// - Returns: the token text, or `nil` when the ID is unknown.
    func convertIdToToken(_ id: Int) -> String? {
        base.convertIdToToken(id)
    }

    /// The beginning-of-sequence token of the wrapped tokenizer.
    var bosToken: String? { base.bosToken }

    /// The end-of-sequence token of the wrapped tokenizer.
    var eosToken: String? { base.eosToken }

    /// The unknown token of the wrapped tokenizer.
    var unknownToken: String? { base.unknownToken }

    /// Renders the conversation with the pinned date in the template context.
    ///
    /// - Parameters:
    ///   - messages: array of message dictionaries representing the conversation.
    ///   - tools: optional array of tool specifications available to the model.
    ///   - additionalContext: optional extra template variables.
    /// - Returns: token IDs for the rendered conversation.
    /// - Throws: whatever the wrapped tokenizer throws.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(
            messages: messages, tools: tools,
            additionalContext: pinningDate(in: additionalContext))
    }

    /// Renders the conversation with the pinned date, and with the
    /// generation-priming region the call asked for.
    ///
    /// Forwarded rather than left to the protocol's `nil` default, so wrapping
    /// a tokenizer never costs it a capability it has.
    ///
    /// - Parameters:
    ///   - messages: array of message dictionaries representing the conversation.
    ///   - tools: optional array of tool specifications available to the model.
    ///   - additionalContext: optional extra template variables.
    ///   - addGenerationPrompt: whether to append the generation-priming region.
    /// - Returns: token IDs for the rendered conversation, or `nil` when the
    ///   wrapped tokenizer does not support controlling the generation prompt.
    /// - Throws: whatever the wrapped tokenizer throws.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int]? {
        try base.applyChatTemplate(
            messages: messages, tools: tools,
            additionalContext: pinningDate(in: additionalContext),
            addGenerationPrompt: addGenerationPrompt)
    }
}
