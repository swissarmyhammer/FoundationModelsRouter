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
    /// Each batch of questions that the session sends to the model opens one
    /// OpenTelemetry span named ``RouterTelemetry/SpanName/decide``, of kind
    /// `client`, through the tracer that
    /// ``RouterTelemetry/tracer(explicit:)`` resolves from
    /// ``RoutedModel/tracer``. Unbootstrapped, that resolves to a no-op
    /// tracer, so an application that does not trace pays nothing. When the
    /// model throws, the span gets the error status and the type of the error,
    /// never its description, and the error is thrown again. A prewarm opens
    /// no span.
    ///
    /// The span carries three attributes, and their names are stable API:
    ///
    /// | Attribute | Value |
    /// |---|---|
    /// | `router.id` | The resolving router's recording root id. |
    /// | `model.ref` | The chosen model reference, in canonical string form. |
    /// | `decision.question_count` | How many questions the batch holds. |
    ///
    /// No state text, no question text, no option text and no answer value
    /// ever reaches the span. A span leaves the process through whatever
    /// backend the host application bootstrapped, so the payload must stay
    /// free of the caller's own content.
    ///
    /// The `model` of the session is a ``TracedDecisionModel`` over the
    /// decision model of the container. It reports the model identifier and
    /// the capabilities of that model.
    ///
    /// - Parameter state: The state that each question of the session is
    ///   about.
    /// - Returns: A new session.
    public func makeSession(state: DecisionState) -> DecisionSession {
        let model = TracedDecisionModel(
            inner: container.decisionModel, routerId: routerId, modelRef: chosen, tracer: tracer)
        return DecisionSession(model: model, state: state)
    }
}
