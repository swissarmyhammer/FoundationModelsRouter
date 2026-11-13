import FoundationModelsDecision

/// How the decision slot asks its model a decision question.
///
/// ``DecisionSlotPlan`` selects the path from the sizing metadata of the
/// model, and ``PooledDecisionContainer/init(hold:path:)`` makes the decision
/// model of the path.
enum DecisionPath: Sendable {
    /// The decision code of the model makes the prompt and reads the answer:
    /// llama.cpp, from the decision type in the GGUF metadata of the model
    /// (``RepoMetadata/ggufDecisionType``). The router gives no prompt format.
    case native

    /// The router makes the prompt with the format, and reads the answer from
    /// the log probabilities of the model.
    case promptFormat(any DecisionPromptFormat)
}
