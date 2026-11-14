/// How a model turns its reasoning on and off (task ^qmewzw0).
///
/// The router asks for the reasoning off in two places: the summarizer call of
/// a compaction, and the first pass of a recovery after a reasoning stop or a
/// repetition stop. A switchable model turns its reasoning off there. A model
/// that always reasons cannot: it reasons in each pass, and a request to stop
/// changes nothing. Recursive Flint (`mlx-community/flint-oQ8e`) is such a
/// model, and it kept reasoning in plain text after a closed `<think></think>`
/// prefill, so no prompt turns it off. The router then gives it a thinking
/// budget (``thinkingAllowance``) in place of the request.
public enum ReasoningControl: Sendable, Equatable {
    /// The model turns its reasoning on and off: for example Qwen3, whose chat
    /// template reads `enable_thinking`.
    case switchable

    /// The model always reasons, and nothing at the prompt turns it off: for
    /// example DeepSeek-R1 and Recursive Flint.
    case alwaysOn

    /// The model has no control of its reasoning at the prompt, or reports
    /// none.
    case none

    /// The tokens an always-reasoning model may think in a call where the
    /// router asks for the reasoning off (task ^qmewzw0).
    ///
    /// A summarizer call gets it on top of the allowed summary size, and the
    /// first pass of a recovery gets it in place of
    /// ``RepetitionDetection/reasoningTokenLimit``. So the model can think,
    /// and then write its summary or act.
    ///
    /// The size is measured, not guessed. On the summarizer prompt of the
    /// compaction suite, Flint reasoned about 7,500 tokens before a 181-token
    /// summary (run of 2026-11-14), and an allowance of 2,048 left every
    /// summary empty. At about 112 tokens a second, the allowance costs up to
    /// about 70 seconds of reasoning for each summary.
    public static let thinkingAllowance = 8_192
}

/// A `LanguageModel` that reports how it turns its reasoning on and off
/// (tasks ^0dcsd3t, ^bhdj5v9 and ^qmewzw0).
///
/// A backend asks for the reasoning off
/// (``ReasoningOffRequest/reasoningLevel``) only when its model conforms and
/// ``reasoningControl()`` gives ``ReasoningControl/switchable``. The MLX
/// engine refuses "reasoning off" for a model that always reasons, and for a
/// model with no control of its reasoning. Such a model keeps its usual
/// behavior. `MLXLanguageModel` and `LlamaLanguageModel` conform (task
/// ^r0dx34s).
protocol ReasoningControlReporting {
    /// How this model turns its reasoning on and off.
    ///
    /// - Returns: The reasoning control of the model.
    /// - Throws: What the read of the model configuration throws.
    func reasoningControl() async throws -> ReasoningControl
}

/// How the first pass of the model call of a recovery reasons, where the
/// session asks for the reasoning off (task ^qmewzw0).
///
/// A recovery after a reasoning stop or a repetition stop, and the final pass,
/// ask for the reasoning off so that the model acts. A model that always
/// reasons cannot turn it off. Its first pass reasons, under the thinking
/// allowance in place of the reasoning token limit of the session, so it
/// thinks briefly and then acts. Each other model keeps the request for the
/// reasoning off: a switchable model turns its reasoning off, and the backend
/// of a model with no control states no level.
enum RecoveryFirstPass: Equatable {
    /// The first pass runs with the reasoning of the model off
    /// (``ReasoningOffRequest``).
    case reasoningOff

    /// The first pass reasons, and the watch stops its reasoning at
    /// `reasoningTokenLimit` tokens.
    case thinkingBudget(reasoningTokenLimit: Int)

    /// The first pass of a recovery on a model with `control`.
    ///
    /// - Parameter control: The reasoning control of the model.
    init(control: ReasoningControl) {
        switch control {
        case .switchable, .none:
            self = .reasoningOff
        case .alwaysOn:
            self = .thinkingBudget(reasoningTokenLimit: ReasoningControl.thinkingAllowance)
        }
    }
}
