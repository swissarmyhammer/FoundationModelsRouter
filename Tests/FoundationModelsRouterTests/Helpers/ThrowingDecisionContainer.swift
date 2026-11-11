import FoundationModelsDecision

@testable import FoundationModelsRouter

/// A ``LoadedDecisionContainer`` stub whose every decide call throws one
/// given error, so a test can read what the decide span records for a
/// failure.
///
/// ``HandBuiltProfileFixtures/makeProfile(definitionName:chosen:container:router:)``
/// always wraps a ``StubDecisionContainer``, which does not fail for a
/// yes-or-no question. A test that needs a failure builds its
/// ``RoutedDecider`` over this container with
/// ``HandBuiltProfileFixtures/makeDecider(chosen:container:routerId:recorder:tracer:)``.
/// The stub never gives an answer.
struct ThrowingDecisionContainer: LoadedDecisionContainer {
    /// The error that each decide call throws.
    let failure: any Error

    /// A model whose executor throws ``failure``.
    var decisionModel: any DecisionModel { Model(failure: failure) }

    /// The decision model of ``ThrowingDecisionContainer``.
    private struct Model: DecisionModel {
        /// The error that each decide call throws.
        let failure: any Error

        /// The model identifier that a response would report.
        var modelID: String { "\(ThrowingDecisionContainer.self)" }

        /// No limits.
        var capabilities: DecisionCapabilities { DecisionCapabilities() }

        /// Makes the executor of one session.
        ///
        /// - Returns: An executor that throws ``failure``.
        func makeExecutor() -> any DecisionModelExecutor {
            Executor(failure: failure)
        }
    }

    /// The executor of ``Model``.
    private struct Executor: DecisionModelExecutor {
        /// The error that each decide call throws.
        let failure: any Error

        /// Throws ``failure`` and answers nothing.
        ///
        /// - Parameters:
        ///   - questions: The questions. The stub ignores them.
        ///   - state: The state. The stub ignores it.
        /// - Returns: Never returns.
        /// - Throws: ``failure``, always.
        func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
            throw failure
        }
    }
}
