import FoundationModelsExtras

/// The live generation container as a native decision source.
///
/// The Extras model pool gives the container of the first loader of a key to
/// each hold of that key. For a router load of an `.llm` key, that container
/// is a ``LiveLLMContainer``, not the model that it wraps. A pooled native
/// decision model asks the container of its hold through ``PooledDecisions``.
/// Thus the container conforms too, and forwards each call to ``model``, as
/// the ``PooledLogits`` conformance does.
///
/// The forward goes only through `model as? any PooledDecisions`, with no
/// code for one runtime. A GGUF model of llama.cpp conforms, and gives a
/// decision type only when llama.cpp answers decision questions for the type
/// of its GGUF file. For a model that does not conform, the container has no
/// decision type, and each decision throws
/// ``PooledDecisionsModelError/notDecisionCapable(_:)`` with ``ref``.
extension LiveLLMContainer: PooledDecisions {
    /// Gives the decision type name of ``model``.
    ///
    /// - Returns: The decision type name of ``model``, or `nil` when
    ///   ``model`` does not conform to ``PooledDecisions`` or has no decision
    ///   type.
    /// - Throws: The error of ``model``.
    package func decisionType() async throws -> String? {
        try await (model as? any PooledDecisions)?.decisionType()
    }

    /// Answers questions about a state with ``model``. The container gives
    /// `state` and `questions` to ``model`` unchanged, and an error of
    /// ``model`` comes to the caller unchanged.
    ///
    /// - Parameters:
    ///   - state: The state that the questions are about.
    ///   - questions: The questions, in order.
    /// - Returns: The answers of ``model``.
    /// - Throws: ``PooledDecisionsModelError/notDecisionCapable(_:)`` with
    ///   ``ref`` when ``model`` does not conform to ``PooledDecisions``, or the
    ///   error of ``model``.
    package func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws
        -> [PooledDecisionAnswer]
    {
        guard let decisions = model as? any PooledDecisions else {
            throw PooledDecisionsModelError.notDecisionCapable(ref)
        }
        return try await decisions.decide(state: state, questions: questions)
    }
}
