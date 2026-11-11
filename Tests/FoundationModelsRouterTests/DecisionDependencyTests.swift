import Testing

// The two products of the FoundationModelsDecision package. These imports are
// the compile-level check: if the package or a product name is wrong, this
// test target does not compile.
import FoundationModelsDecision
import FoundationModelsDecisionPooled
// The module of `ModelRef`, the type of the name of a pooled model.
import FoundationModelsExtras

@Suite("Decision dependency")
struct DecisionDependencyTests {
    /// The name of a model that the test never loads. A pooled decision model
    /// and a session load nothing until the first question.
    static let unloadedModelReference: ModelRef = "example/unloaded-decision-model"

    /// A session over a pooled decision model with a generic prompt format
    /// keeps the model that it was made with.
    ///
    /// The types `GenericPromptFormat`, `PooledDecisionModel` and
    /// `DecisionSession` must be reachable for this file to compile. The
    /// expectation reads the model back from the session, so the test also
    /// fails at run time if the session does not keep its model.
    @Test("a session keeps its pooled decision model")
    func sessionKeepsItsPooledDecisionModel() {
        let model = PooledDecisionModel(ref: Self.unloadedModelReference, format: GenericPromptFormat())
        let session = DecisionSession(model: model, state: .text("The state of the decision."))

        #expect((session.model as? PooledDecisionModel)?.ref == Self.unloadedModelReference)
    }
}
