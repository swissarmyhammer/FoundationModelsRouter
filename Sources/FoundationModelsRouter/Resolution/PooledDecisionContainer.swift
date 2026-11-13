import FoundationModelsDecision
import FoundationModelsDecisionPooled
import FoundationModelsExtras

/// The decision container of a ``RoutedDecider``: a pooled decision model
/// over the hold of the decision slot.
///
/// The first loader of a key gives the container of all holds of that key, so
/// the container of the hold can come from a loader that is not the router's.
/// The pooled decision model therefore uses it through ``PooledLogits`` on a
/// prompt-format path, and through ``PooledDecisions`` on the native path
/// (``DecisionPath``). For a router load, that container is
/// ``LiveLLMContainer``, which forwards both to its model.
///
/// The container gives the format to the pooled decision model unchanged.
/// A thinking block before the answer gives incorrect probabilities, thus
/// `GenericPromptFormat` with no closed-think fallback refuses a chat
/// template that leaves a thinking block open when reasoning is off.
///
/// The type is `package`, so that the real-model harness of the test targets
/// gives its hand-built profile a real decision container.
package struct PooledDecisionContainer: LoadedDecisionContainer {
    /// The pooled decision model over the hold.
    package let decisionModel: any DecisionModel

    /// Makes the container of a decision hold.
    ///
    /// The native path gives a `PooledNativeDecisionModel`: the decision code
    /// of the model makes the prompt and reads the answer. A prompt-format
    /// path gives a `PooledDecisionModel` with the format.
    ///
    /// - Parameters:
    ///   - hold: A hold of an LLM.
    ///   - path: The decision path of the model.
    /// - Throws: On the native path,
    ///   `PooledDecisionsModelError.notDecisionCapable(_:)` when the container
    ///   of `hold` does not conform to ``PooledDecisions``. On a prompt-format
    ///   path, ``PooledLogitsModelError/notLogitsCapable(_:)`` when the
    ///   container of `hold` does not conform to ``PooledLogits``.
    init(hold: ModelHold, path: DecisionPath) throws {
        switch path {
        case .native:
            decisionModel = try PooledNativeDecisionModel(hold: hold)
        case .promptFormat(let format):
            decisionModel = try PooledDecisionModel(hold: hold, format: format)
        }
    }

    /// Makes the container of a decision model that `pool` loads at the
    /// first question of each session. This loads nothing.
    ///
    /// A profile that a caller builds by hand has no hold. Its decision model
    /// takes a hold of `ref` in `pool` when a session asks its first question.
    /// A container of the pool that does not conform to ``PooledLogits``
    /// makes that question throw ``PooledLogitsModelError/notLogitsCapable(_:)``.
    ///
    /// - Parameters:
    ///   - ref: The model of the decision slot.
    ///   - pool: The pool that loads `ref` as an LLM.
    ///   - format: The prompt format of the model. The default is the format
    ///     of the flash fallback, `GenericPromptFormat`.
    package init(model ref: ModelRef, pool: ModelPool, format: any DecisionPromptFormat = GenericPromptFormat()) {
        decisionModel = PooledDecisionModel(ref: ref, pool: pool, format: format)
    }
}

/// The decision container of a decision hold whose container cannot answer
/// on its decision path, for example a stub LLM container of a test, or a
/// container of a loader that is not the router's.
///
/// The resolve does not fail for such a hold: the decision slot never stops a
/// profile. Instead, each decision of the container throws the error that
/// ``PooledDecisionContainer/init(hold:path:)`` threw, usually
/// ``PooledLogitsModelError/notLogitsCapable(_:)`` or
/// `PooledDecisionsModelError.notDecisionCapable(_:)`.
struct UnavailableDecisionContainer: LoadedDecisionContainer {
    /// The model whose each decision throws the error.
    let decisionModel: any DecisionModel

    /// Makes a container whose each decision throws `error`.
    ///
    /// - Parameters:
    ///   - ref: The model of the decision hold.
    ///   - error: The error that each decision throws.
    init(ref: ModelRef, error: any Error) {
        decisionModel = UnavailableDecisionModel(ref: ref, error: error)
    }
}

/// The decision model of an ``UnavailableDecisionContainer``: each decision
/// throws one fixed error.
private struct UnavailableDecisionModel: DecisionModel {
    /// The model of the decision hold.
    let ref: ModelRef

    /// The error that each decision throws.
    let error: any Error

    /// The text of the model reference.
    var modelID: String { ref.stringValue }

    /// No limits: each question gets the error.
    var capabilities: DecisionCapabilities { DecisionCapabilities() }

    /// Makes the executor of one session.
    ///
    /// - Returns: An executor whose each decision throws ``error``.
    func makeExecutor() -> any DecisionModelExecutor {
        UnavailableDecisionExecutor(error: error)
    }
}

/// The executor of an ``UnavailableDecisionModel``.
private struct UnavailableDecisionExecutor: DecisionModelExecutor {
    /// The error that each decision throws.
    let error: any Error

    /// Throws ``error``, and answers no question.
    ///
    /// - Parameters:
    ///   - questions: The questions. Unread.
    ///   - state: The state. Unread.
    /// - Returns: Never returns.
    /// - Throws: ``error``, always.
    func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
        throw error
    }
}
