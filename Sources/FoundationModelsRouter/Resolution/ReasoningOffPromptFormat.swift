import FoundationModelsDecision

/// A prompt format that refuses a chat template that cannot turn reasoning
/// off.
///
/// A decision reads the answer from the first token of the reply. When the
/// chat template leaves a thinking block open, the first token starts the
/// reasoning and not the answer, and the probabilities are not correct. The
/// fallback of the decision slot is the flash model, which can be a reasoning
/// model. Thus each chat template that the wrapped format renders with
/// reasoning off must end with no open thinking block. Else the plan throws
/// ``DecisionError/unsupportedModel(_:)``, before the model evaluates a
/// prompt.
///
/// Only a format that does not close an open thinking block itself needs the
/// check (see ``guarding(_:)``).
struct ReasoningOffPromptFormat: DecisionPromptFormat {
    /// The texts that open a thinking block at the end of a chat template:
    /// the Qwen and DeepSeek form, and the Gemma form. These are the thinking
    /// blocks that decider-ai closes.
    static let openThinkingMarkers = ["<think>", "<|channel>thought"]

    /// The detail of the error for a chat template that leaves a thinking
    /// block open.
    static let openThinkingMessage =
        "The chat template of the model leaves a thinking block open when reasoning is off, "
        + "thus the model cannot give correct probabilities."

    /// The format that makes the prompts.
    let wrapped: any DecisionPromptFormat

    /// Adds the check to a format that needs it.
    ///
    /// A ``GenericPromptFormat`` with no closed-think fallback uses the chat
    /// template as it renders, thus it gets the check. Each other format
    /// does not change: the generic format with the fallback closes an open
    /// block itself, and ``DeciderPromptFormat`` closes the blocks of
    /// decider-ai itself.
    ///
    /// - Parameter format: The format of a decision model.
    /// - Returns: `format` with the check, or `format` unchanged.
    static func guarding(_ format: any DecisionPromptFormat) -> any DecisionPromptFormat {
        guard let generic = format as? GenericPromptFormat, !generic.closedThinkFallback else { return format }
        return ReasoningOffPromptFormat(wrapped: generic)
    }

    /// Tells if a rendered chat template ends in an open thinking block. The
    /// whitespace at the end does not count.
    ///
    /// - Parameter rendered: The rendered chat template.
    /// - Returns: `true` when the text, with no whitespace at the end, ends
    ///   with one of ``openThinkingMarkers``.
    static func endsInOpenThinkingBlock(_ rendered: String) -> Bool {
        let trimmed = String(rendered.reversed().drop(while: \.isWhitespace).reversed())
        return openThinkingMarkers.contains { trimmed.hasSuffix($0) }
    }

    /// The limits of the wrapped format.
    ///
    /// - Returns: The limits that the wrapped format gives.
    func capabilities() -> DecisionCapabilities {
        wrapped.capabilities()
    }

    /// Makes the prompts of one question with the wrapped format, over a
    /// source that checks each chat template that the format renders.
    ///
    /// - Parameters:
    ///   - question: The question.
    ///   - state: The state that the question is about.
    ///   - index: The position of the question in its batch, for the errors.
    ///   - source: The source that tokenizes the text and renders the chat
    ///     template.
    /// - Returns: The plan of the wrapped format.
    /// - Throws: ``DecisionError/unsupportedModel(_:)`` when a chat template
    ///   with reasoning off ends in an open thinking block, or the error of
    ///   the wrapped format.
    func plan(
        for question: Question,
        about state: DecisionState,
        index: Int,
        using source: any DecisionLogitsSource
    ) async throws -> DecisionPromptPlan {
        try await wrapped.plan(
            for: question, about: state, index: index, using: ReasoningOffSource(wrapped: source))
    }
}

/// A source that checks each chat template that it renders with reasoning
/// off. Each other call goes to the wrapped source unchanged.
private struct ReasoningOffSource: DecisionLogitsSource {
    /// The source that does the work.
    let wrapped: any DecisionLogitsSource

    /// The model identifier of the wrapped source.
    var modelID: String { wrapped.modelID }

    /// The prompt limit of the wrapped source.
    var maximumPromptTokens: Int? { wrapped.maximumPromptTokens }

    /// Tokenizes with the wrapped source.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs that the wrapped source gives.
    /// - Throws: The error of the wrapped source.
    func tokenize(_ text: String) async throws -> [Int] {
        try await wrapped.tokenize(text)
    }

    /// Renders with the wrapped source, and checks the text when reasoning is
    /// off.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order.
    ///   - reasoning: `true` to let the model reason, `false` to turn
    ///     reasoning off.
    /// - Returns: The text that the wrapped source gives.
    /// - Throws: ``DecisionError/unsupportedModel(_:)`` when `reasoning` is
    ///   `false` and the text ends in an open thinking block, or the error of
    ///   the wrapped source.
    func renderChatTemplate(_ messages: [ChatMessage], reasoning: Bool) async throws -> String? {
        let rendered = try await wrapped.renderChatTemplate(messages, reasoning: reasoning)
        if !reasoning, let rendered, ReasoningOffPromptFormat.endsInOpenThinkingBlock(rendered) {
            throw DecisionError.unsupportedModel(ReasoningOffPromptFormat.openThinkingMessage)
        }
        return rendered
    }

    /// Reads the log probabilities from the wrapped source.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts, each as token IDs.
    /// - Returns: The rows that the wrapped source gives.
    /// - Throws: The error of the wrapped source.
    func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        try await wrapped.logProbabilities(of: candidates, after: prompts)
    }
}
