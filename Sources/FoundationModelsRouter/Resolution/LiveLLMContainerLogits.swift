import FoundationModelsExtras

/// The live generation container as a log-probability source.
///
/// The Extras model pool gives the container of the first loader of a key to
/// each hold of that key. For a router load of an `.llm` key, that container
/// is a ``LiveLLMContainer``, not the model that it wraps. A pooled decision
/// model reads the logits of the container of its hold through
/// ``PooledLogits``. Thus the container conforms too, and forwards each call
/// to ``model``.
///
/// The forward goes only through `model as? any PooledLogits`, with no code
/// for one runtime, thus an MLX model and a llama.cpp model both work. For a
/// model that gives no logits, each call throws
/// ``PooledLogitsModelError/notLogitsCapable(_:)`` with ``ref``.
extension LiveLLMContainer: PooledLogits {
    /// The prompt limit of ``model``, or `nil` when ``model`` gives no logits
    /// or has no fixed limit.
    package var maximumPromptTokens: Int? {
        (model as? any PooledLogits)?.maximumPromptTokens
    }

    /// Tokenizes text with ``model``.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The token IDs of the text, with no BOS token and no EOS
    ///   token.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` when
    ///   ``model`` gives no logits, or the error of ``model``.
    package func tokenize(_ text: String) async throws -> [Int] {
        try await logitsModel().tokenize(text)
    }

    /// Renders the chat template of ``model`` as text, with the generation
    /// prompt.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, in order. Each message has the
    ///     keys `role` and `content` only.
    ///   - reasoning: `true` to let the model reason before it replies,
    ///     `false` to turn reasoning off.
    /// - Returns: The rendered text, or `nil` if the model has no chat
    ///   template.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` when
    ///   ``model`` gives no logits, or the error of ``model``.
    package func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        try await logitsModel().renderChatTemplate(messages, reasoning: reasoning)
    }

    /// Gives the log probabilities of candidate tokens at the last position of
    /// each prompt, from ``model``.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts, each as token IDs.
    /// - Returns: One row for each prompt, with one log probability for each
    ///   candidate.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` when
    ///   ``model`` gives no logits, or the error of ``model``.
    package func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        try await logitsModel().logProbabilities(of: candidates, after: prompts)
    }

    /// Gives ``model`` as a log-probability source.
    ///
    /// - Returns: ``model``.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` with ``ref``
    ///   when ``model`` does not conform to ``PooledLogits``.
    private func logitsModel() throws -> any PooledLogits {
        guard let logits = model as? any PooledLogits else {
            throw PooledLogitsModelError.notLogitsCapable(ref)
        }
        return logits
    }
}
