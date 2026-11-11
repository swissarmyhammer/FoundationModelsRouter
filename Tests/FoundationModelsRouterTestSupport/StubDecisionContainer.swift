import FoundationModelsDecision
import FoundationModelsRouter

/// A ``LoadedDecisionContainer`` over a ``StubDecisionModel``: the decision
/// container of a profile that a test builds by hand.
///
/// A hand-built profile resolves nothing, thus it holds no model that can give
/// log probabilities. This container answers each decision with no model.
public struct StubDecisionContainer: LoadedDecisionContainer {
    /// The stub model that answers each question.
    public let decisionModel: any DecisionModel

    /// Makes a container over a ``StubDecisionModel``.
    ///
    /// - Parameter modelID: The model identifier that each response of the
    ///   stub model reports.
    public init(modelID: String) {
        decisionModel = StubDecisionModel(modelID: modelID)
    }
}

/// A ``DecisionModel`` with no model behind it.
///
/// The model answers each yes-or-no question with a probability that it
/// derives from the instructions of the question (``probability(of:)``). Thus
/// two questions whose instructions have different lengths get different
/// probabilities, and a caller that sends the wrong question gets a different
/// value. The model answers no choice question and no score question.
public struct StubDecisionModel: DecisionModel {
    /// The model identifier that each response reports.
    public let modelID: String

    /// No limits.
    public var capabilities: DecisionCapabilities { DecisionCapabilities() }

    /// Makes a stub model.
    ///
    /// - Parameter modelID: The model identifier that each response reports.
    public init(modelID: String) {
        self.modelID = modelID
    }

    /// Makes the executor of one session.
    ///
    /// - Returns: An executor that answers with ``probability(of:)``.
    public func makeExecutor() -> any DecisionModelExecutor {
        StubDecisionExecutor(modelID: modelID)
    }

    /// The probability of "yes" that the stub gives for a yes-or-no question:
    /// the count of the characters of `instructions`, divided by that count
    /// plus one. The value is in `0..<1`, and it is larger for longer
    /// instructions.
    ///
    /// - Parameter instructions: The instructions of the question.
    /// - Returns: The probability of "yes".
    public static func probability(of instructions: String) -> Double {
        let characterCount = Double(instructions.count)
        return characterCount / (characterCount + 1)
    }
}

/// The executor of ``StubDecisionModel``.
private struct StubDecisionExecutor: DecisionModelExecutor {
    /// The model identifier that each response reports.
    let modelID: String

    /// Answers each yes-or-no question with ``StubDecisionModel/probability(of:)``.
    ///
    /// - Parameters:
    ///   - questions: The questions.
    ///   - state: The state. Unread.
    /// - Returns: One answer for each question.
    /// - Throws: ``DecisionError/unsupportedQuestion(index:reason:)`` for a
    ///   question that is not a yes-or-no question.
    func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
        DecisionSession.Response(
            modelID: modelID,
            answers: try questions.enumerated().map { index, question in
                guard case .binary(let instructions, _) = question else {
                    throw DecisionError.unsupportedQuestion(
                        index: index, reason: "The stub decision model answers yes-or-no questions only.")
                }
                return .binary(probability: StubDecisionModel.probability(of: instructions))
            })
    }
}
