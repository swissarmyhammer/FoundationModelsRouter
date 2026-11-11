import FoundationModelsDecision
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of ``RoutedDecider``: a session that the handle makes answers
/// through the decision model of its container.
@Suite("The decision handle")
struct RoutedDeciderTests {
    // MARK: - Fixed values

    /// The model reference of the handle.
    private static let ref: ModelRef = "org/decider-stub"

    /// The probability of "yes" that the stub model gives.
    private static let stubProbability = 0.75

    /// The state of each session.
    private static let state: DecisionState = "The build is red."

    /// The yes-or-no question of each test.
    private static let question = "Does the state report a failure?"

    // MARK: - Stubs

    /// A decision model whose executor answers each binary question with
    /// ``RoutedDeciderTests/stubProbability``.
    private struct StubDecisionModel: DecisionModel {
        /// The model reference, as text.
        var modelID: String { RoutedDeciderTests.ref.stringValue }

        /// No limits.
        var capabilities: DecisionCapabilities { DecisionCapabilities() }

        /// Makes the executor of one session.
        ///
        /// - Returns: The stub executor.
        func makeExecutor() -> any DecisionModelExecutor {
            StubDecisionExecutor()
        }
    }

    /// The executor of ``StubDecisionModel``.
    private struct StubDecisionExecutor: DecisionModelExecutor {
        /// Answers each question with a binary answer of
        /// ``RoutedDeciderTests/stubProbability``.
        ///
        /// - Parameters:
        ///   - questions: The questions.
        ///   - state: The state. Unread.
        /// - Returns: One answer for each question.
        func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
            DecisionSession.Response(
                modelID: RoutedDeciderTests.ref.stringValue,
                answers: questions.map { _ in .binary(probability: RoutedDeciderTests.stubProbability) })
        }
    }

    /// A decision container over ``StubDecisionModel``.
    private struct StubDecisionContainer: LoadedDecisionContainer {
        /// The stub model.
        var decisionModel: any DecisionModel { StubDecisionModel() }
    }

    // MARK: - Helpers

    /// Makes a decision handle over ``StubDecisionContainer``. The handle
    /// reads no slot: the `decision` slot comes with a later task, thus the
    /// handle names the `flash` slot, which a decision falls back to.
    ///
    /// - Returns: The handle.
    private static func makeDecider() -> RoutedDecider {
        RoutedDecider(
            slot: .flash,
            chosen: ref,
            footprintBytes: 0,
            resolution: SlotResolution(
                slot: .flash, remainingBudgetBytes: 0, chosen: ref, considered: [],
                contextTokens: ScriptedSessionContext.tokens),
            container: StubDecisionContainer(),
            routerId: ULID(),
            recorder: InMemoryRecorder()
        )
    }

    // MARK: - Tests

    /// A session of the handle answers through the stub model.
    @Test("a session of the decider gives the probability of the stub model")
    func sessionAnswersThroughTheContainerModel() async throws {
        let session = Self.makeDecider().makeSession(state: Self.state)
        #expect(try await session.probability(of: Self.question) == Self.stubProbability)
    }

    /// A session of the handle is about the state that the caller gives.
    @Test("a session of the decider keeps the state of the caller")
    func sessionKeepsTheState() {
        let session = Self.makeDecider().makeSession(state: Self.state)
        #expect(session.state == Self.state)
    }
}
