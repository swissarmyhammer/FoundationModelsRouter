import FoundationModelsDecision
import FoundationModelsDecisionPooled
import FoundationModelsExtras

/// The decision container of a ``RoutedDecider``: a pooled decision model
/// over the hold of the decision slot.
///
/// The first loader of a key gives the container of all holds of that key, so
/// the container of the hold can come from a loader that is not the router's.
/// The pooled decision model therefore uses it through ``PooledLogits`` only.
/// For a router load, that container is ``LiveLLMContainer``.
///
/// The container checks that the chat template turns reasoning off. A
/// thinking block before the answer gives incorrect probabilities, thus the
/// container refuses a template that leaves a thinking block open (see
/// ``ReasoningOffPromptFormat``).
struct PooledDecisionContainer: LoadedDecisionContainer {
    /// The pooled decision model over the hold.
    let decisionModel: any DecisionModel

    /// Makes the container of a decision hold.
    ///
    /// - Parameters:
    ///   - hold: A hold of an LLM.
    ///   - format: The prompt format of the model.
    /// - Throws: ``PooledLogitsModelError/notLogitsCapable(_:)`` when the
    ///   container of `hold` does not conform to ``PooledLogits``.
    init(hold: ModelHold, format: any DecisionPromptFormat) throws {
        decisionModel = try PooledDecisionModel(hold: hold, format: ReasoningOffPromptFormat.guarding(format))
    }
}
