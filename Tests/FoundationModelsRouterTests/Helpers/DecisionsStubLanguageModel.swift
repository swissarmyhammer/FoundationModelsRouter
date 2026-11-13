import FoundationModels
import FoundationModelsExtras

/// A `LanguageModel` that conforms to ``PooledDecisions``, with no model
/// behind it: the stub of a GGUF decision model that llama.cpp answers
/// natively.
///
/// The stub has a fixed decision type. It answers each question with the
/// probability ``trueProbability`` for the option `"true"`, and gives the rest
/// to the other options, in equal parts. Thus a caller that reads the wrong
/// option gets a different value.
struct DecisionsStubLanguageModel: FoundationModels.LanguageModel, PooledDecisions {
    /// The option key of the "yes" answer of a noul question.
    private static let trueKey = "true"

    /// The probability that the stub gives to the option `"true"`.
    static let trueProbability = 0.75

    /// The decision type name that the stub gives, or `nil` for a model with
    /// no decision type.
    let type: String?

    /// No capabilities.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor, which runs no generation.
    typealias Executor = UndrivenExecutor<DecisionsStubLanguageModel>

    /// The one cache key of the executor.
    var executorConfiguration: Executor.Configuration { .init() }

    /// Gives ``type``.
    ///
    /// - Returns: ``type``.
    func decisionType() async throws -> String? {
        type
    }

    /// Answers each question: ``trueProbability`` for the option `"true"`,
    /// and the rest to the other options, in equal parts.
    ///
    /// - Parameters:
    ///   - state: The state. Unread.
    ///   - questions: The questions, in order.
    /// - Returns: One answer for each question, in question order.
    func decide(state: PooledDecisionState, questions: [PooledDecisionQuestion]) async throws
        -> [PooledDecisionAnswer]
    {
        questions.map { question in
            let otherCount = Double(question.options.filter { $0.key != Self.trueKey }.count)
            return PooledDecisionAnswer(
                id: question.id,
                probabilities: question.options.map {
                    $0.key == Self.trueKey ? Self.trueProbability : (1 - Self.trueProbability) / otherCount
                },
                expectedValue: nil)
        }
    }
}
