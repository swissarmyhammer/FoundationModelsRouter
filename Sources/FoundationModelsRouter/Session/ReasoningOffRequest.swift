import FoundationModels

/// A `LanguageModel` that can turn its reasoning off for one pass
/// (tasks ^0dcsd3t and ^bhdj5v9).
///
/// A backend asks for the reasoning off
/// (``ReasoningOffRequest/reasoningLevel``) only when its model conforms and
/// ``canTurnReasoningOff()`` gives `true`. The MLX engine refuses "reasoning
/// off" for a model that always reasons, and for a model with no control of
/// its reasoning. Such a model keeps its usual behavior.
protocol ReasoningSwitchable {
    /// Whether a call can ask this model to turn its reasoning off.
    ///
    /// - Returns: `true` when the model turns its reasoning on and off.
    /// - Throws: What the read of the model configuration throws.
    func canTurnReasoningOff() async throws -> Bool
}

/// The request that the first pass of the model call on this task runs with
/// the reasoning of its model off (tasks ^0dcsd3t and ^bhdj5v9).
///
/// A recovery after a reasoning stop or a repetition stop tells the model to
/// act. A text that says "do not reason" does not stop a thinking pass of a
/// reasoning model: the chat template opens a new thought, and the model
/// reasons for one more full pass. So the session runs the first pass of the
/// model call of the recovery with the reasoning of the model off, and the
/// model must write a tool call or text. When that pass calls a tool, each
/// later pass of the tool loop of the call runs with the reasoning on. A
/// stop in a later pass goes to the repetition watch and its recovery
/// count, as any other stop does.
///
/// The session binds the request around the model work of the recovery
/// attempt (``requested(around:)``). The queue of the model runs that work on
/// a task of its own, and the binding goes with the work. The backend reads
/// ``isRequested`` when it starts the call, and states the level for the
/// first pass of the call only
/// (``SessionLanguageModelState/setFirstPassReasoningLevel(_:)``).
enum ReasoningOffRequest {
    /// Whether the first pass of the model call that starts on this task
    /// runs with the reasoning of its model off.
    @TaskLocal static var isRequested = false

    /// The reasoning level that asks the MLX engine to turn the reasoning of
    /// the model off.
    ///
    /// `MLXLanguageModel` reads `.custom("no_think")`, and only that value, as
    /// "reasoning off". For a model that turns its reasoning on and off with
    /// a chat template flag, the engine then renders the prompt with that
    /// flag off: for Qwen3, `enable_thinking` is `false` in the additional
    /// context of the template. The level applies to the one pass that
    /// states it: the first pass of the call. The SDK call itself states no
    /// level, so each later pass of its tool loop reasons as usual.
    static let reasoningLevel = ContextOptions.ReasoningLevel.custom("no_think")

    /// `body`, with the request bound around each call of it.
    ///
    /// - Parameter body: The model work of one submission.
    /// - Returns: The model work whose first pass runs with the reasoning off.
    static func requested(
        around body: @escaping @Sendable (String) async throws -> String
    ) -> @Sendable (String) async throws -> String {
        { composedPrompt in
            try await $isRequested.withValue(true) {
                try await body(composedPrompt)
            }
        }
    }
}
