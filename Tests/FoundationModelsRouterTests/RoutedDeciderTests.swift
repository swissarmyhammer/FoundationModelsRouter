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

    /// The state of each session.
    private static let state: DecisionState = "The build is red."

    /// The yes-or-no questions of the tests, each with the probability of
    /// "yes" that the stub model gives for it. Each question has a different
    /// probability, thus a session that gives one fixed value fails a test.
    private static let answers = [
        "Does the state report a failure?": 0.75,
        "Does the state report a success?": 0.25,
    ]

    // MARK: - Stubs

    /// The error of the stub executor.
    private enum StubDecisionError: Error {
        /// The question is not a binary question of ``RoutedDeciderTests/answers``.
        case unknownQuestion(Question)
    }

    /// A decision model whose executor answers each binary question with the
    /// probability that ``RoutedDeciderTests/answers`` gives for it.
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
        /// Answers each question with a binary answer, with the probability
        /// that ``RoutedDeciderTests/answers`` gives for its instructions.
        ///
        /// - Parameters:
        ///   - questions: The questions.
        ///   - state: The state. Unread.
        /// - Returns: One answer for each question.
        /// - Throws: ``StubDecisionError/unknownQuestion(_:)`` for a question
        ///   that is not a binary question of ``RoutedDeciderTests/answers``.
        func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
            DecisionSession.Response(
                modelID: RoutedDeciderTests.ref.stringValue,
                answers: try questions.map { .binary(probability: try Self.probability(of: $0)) })
        }

        /// Gives the probability of "yes" for `question`.
        ///
        /// - Parameter question: The question.
        /// - Returns: The probability that ``RoutedDeciderTests/answers``
        ///   gives for the instructions of `question`.
        /// - Throws: ``StubDecisionError/unknownQuestion(_:)`` for a question
        ///   that is not a binary question of ``RoutedDeciderTests/answers``.
        private static func probability(of question: Question) throws -> Double {
            guard case .binary(let instructions, _) = question,
                let probability = RoutedDeciderTests.answers[instructions]
            else {
                throw StubDecisionError.unknownQuestion(question)
            }
            return probability
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

    /// A session of the handle answers each question through the stub
    /// model, with the probability of that question.
    @Test(
        "a session of the decider gives the probability of the stub model for each question",
        arguments: answers.keys.sorted())
    func sessionAnswersThroughTheContainerModel(question: String) async throws {
        let session = Self.makeDecider().makeSession(state: Self.state)
        #expect(try await session.probability(of: question) == Self.answers[question])
    }

    /// A session of the handle is about the state that the caller gives.
    @Test("a session of the decider keeps the state of the caller")
    func sessionKeepsTheState() {
        let session = Self.makeDecider().makeSession(state: Self.state)
        #expect(session.state == Self.state)
    }
}
