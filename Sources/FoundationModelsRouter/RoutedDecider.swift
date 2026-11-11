import FoundationModelsDecision

/// The decision access surface on the decision handle.
///
/// ``RoutedDecider`` is `RoutedModel<any LoadedDecisionContainer>`, so the
/// decision-only API arrives here as a container-constrained extension. It is
/// not available on the generation handle ``RoutedLLM`` or on the embedding
/// handle ``RoutedEmbedder``.
///
/// A decision writes nothing to the transcript, the same as an embed call: a
/// decision is not part of the conversation of a session.
extension RoutedModel where Container == any LoadedDecisionContainer {
    /// Makes a decision session about `state` over the decision model of the
    /// resident container.
    ///
    /// Each question of the session goes to the decision model of the
    /// container. The session writes nothing to the transcript. The questions
    /// are independent: an answer is never history for a later question.
    ///
    /// - Parameter state: The state that each question of the session is
    ///   about.
    /// - Returns: A new session.
    public func makeSession(state: DecisionState) -> DecisionSession {
        DecisionSession(model: container.decisionModel, state: state)
    }
}
