import Foundation
import FoundationModels
import FoundationModelsDecision
import FoundationModelsDecisionPooled
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

// MARK: - Models

/// The decision model of this suite: `decider-2b` in the `Q4_K_M` GGUF
/// conversion, about 1.3 GB, at the revision of the Metal reference of the
/// FoundationModelsDecision package.
///
/// The revision is the revision of
/// `Tests/FoundationModelsDecisionTests/Fixtures/decider-metal-reference.json`
/// of that package. Each reference value of ``deciderReferenceItems`` comes from
/// the files of this revision, so a later revision cannot change them.
private let deciderModel = ModelRef(
    repo: "Mapika/decider-2b-GGUF",
    path: "decider-2b-v12-Q4_K_M.gguf",
    revision: "0df001b8fe4e5298c5dd45d875d3795fcdaea0ab"
)

/// The `standard` candidate of each profile of this suite: the small MLX
/// instruct model of `GGUFProfileIntegrationTests`, 680 MB. No test of this
/// suite generates on it.
private let standardModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The `flash` candidate of each profile of this suite: the GGUF model of
/// `GGUFProfileIntegrationTests`, Qwen3.5 0.8B in the ggml-org Q8_0
/// conversion, 834 MB.
///
/// The flash model is a GGUF model, so the flash fallback of the decision slot
/// reads its decisions through llama.cpp. A decision and a generation on the
/// same llama.cpp model then share the lock of that model.
private let flashModel: ModelRef = "ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf"

/// The working context of each profile of this suite, in tokens: the `n_ctx`
/// of the 2b model in the Metal reference.
///
/// llama.cpp loads a GGUF model at a fixed context, which the router gives it
/// from the resolution. The decider then evaluates each prompt at the context
/// of the reference.
private let decisionProfileContext = 4096

/// The decoding of each router of this suite: argmax, the pin every gated
/// suite of this target states.
private let decisionSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The largest permitted absolute difference between an answer probability and
/// the probability of the reference: the limit of the Metal reference test of
/// the FoundationModelsDecision package.
private let referenceProbabilityTolerance = 0.005

/// The probability of "yes" at and above which a yes/no answer is "yes", as
/// the script that made the Metal reference reads it.
private let binaryYesThreshold = 0.5

/// The token ceiling of each generation call of the flash answer of the
/// concurrency test. Qwen3.5 can reason to the ceiling, and the session then
/// recovers with more calls in the same answer.
private let flashAnswerTokenCeiling = 128

/// The instructions of the flash session of the concurrency test.
private let flashInstructions = "You are a terse assistant."

/// The prompt of the flash answer of the concurrency test: an easy list, so
/// the generation runs for many tokens.
private let flashPrompt = "Count from one to twenty in words, separated by commas."

// MARK: - Reference items

/// One item of the Metal reference, with the result of the 2b model.
private struct DeciderReferenceItem: Sendable {
    /// The name of the item in the reference file.
    let id: String

    /// The state of the question.
    let state: DecisionState

    /// The question.
    let question: Question

    /// The answer probabilities of the reference, in option order. For a
    /// yes/no question the order is "no", "yes".
    let probabilities: [Double]

    /// The index of the top answer of the reference in ``probabilities``.
    let topIndex: Int
}

/// The yes/no item `binary-invoice-paid` of the reference. Its answer is clear,
/// so the flash fallback must also answer "yes".
private let invoicePaidItem = DeciderReferenceItem(
    id: "binary-invoice-paid",
    state: .text("The invoice was paid in full on March 3."),
    question: .binary(instructions: "Has the invoice been paid?"),
    probabilities: [0.0, 1.0],
    topIndex: 1
)

/// Three items of the reference, one of each kind of question, with the
/// result of the 2b model. The values are copies of the reference file.
private let deciderReferenceItems: [DeciderReferenceItem] = [
    invoicePaidItem,
    DeciderReferenceItem(
        id: "choice-department-billing",
        state: .text("My card was charged twice for the same purchase."),
        question: .choice(
            instructions: "Which department should handle this?",
            options: [ChoiceOption("billing"), ChoiceOption("technical"), ChoiceOption("sales")]
        ),
        probabilities: [0.9480238662811801, 0.025007250066927635, 0.026968883651892286],
        topIndex: 0
    ),
    DeciderReferenceItem(
        id: "score-toxicity-high",
        state: .text("You are an idiot and nobody wants you here."),
        question: .score(
            instructions: "How toxic is the message?",
            levels: ["not toxic", "slightly toxic", "very toxic"]
        ),
        probabilities: [0.11616452736265911, 0.18589375136494343, 0.6979417212723975],
        topIndex: 2
    ),
]

/// The errors of the reference comparison of this suite.
private enum DecisionSlotTestError: Error {
    /// The answer is not of the kind of the question of the item.
    case answerKindMismatch(item: String)

    /// The choice answer has no probability for an option of the item.
    case missingOption(item: String, option: String)
}

// MARK: - Profiles

/// Makes the profile of this suite with the decision candidates `decision`.
///
/// - Parameter decision: The candidates of the decision slot.
/// - Returns: The profile.
private func decisionProfile(decision: [ModelRef]) -> ProfileDefinition {
    ProfileDefinition(
        name: "decision-slot",
        description: "Small standard and flash models beside a decision slot.",
        standard: [standardModel],
        flash: [flashModel],
        embedding: [RealModels.embedding],
        decision: decision,
        context: decisionProfileContext
    )
}

/// The profile whose decision slot names ``deciderModel``.
private let deciderProfile = decisionProfile(decision: [deciderModel])

/// The profile whose decision slot names no candidate, so the decision slot
/// uses the flash model.
private let flashFallbackProfile = decisionProfile(decision: [])

// MARK: - Fixture

/// The questions and the answers of the decision slot of a resolved profile.
private enum DecisionSlotProbe {
    /// The prompt format of the decision slot of `profile`.
    ///
    /// - Parameter profile: The resolved profile.
    /// - Returns: The format of the pooled decision model of the slot.
    /// - Throws: An expectation failure when the decision model of the slot is
    ///   not a `PooledDecisionModel`.
    static func format(of profile: LanguageModelProfile) throws -> any DecisionPromptFormat {
        try #require(profile.decision.container.decisionModel as? PooledDecisionModel).format
    }

    /// Asks the question of `item` in a new session of the decision slot.
    ///
    /// - Parameters:
    ///   - item: The item.
    ///   - decider: The decision slot.
    /// - Returns: The answer.
    /// - Throws: The error of the session.
    static func ask(_ item: DeciderReferenceItem, on decider: RoutedDecider) async throws -> Answer {
        try await decider.makeSession(state: item.state).decide(item.question)
    }

    /// The answer probabilities of `answer` in the option order of `item`, the
    /// order of the reference. For a yes/no question the order is "no", "yes".
    ///
    /// - Parameters:
    ///   - answer: The answer.
    ///   - item: The item that the answer is for.
    /// - Returns: The probabilities.
    /// - Throws: ``DecisionSlotTestError`` when the answer is not of the kind
    ///   of the question, or has no probability for an option.
    static func probabilities(of answer: Answer, for item: DeciderReferenceItem) throws -> [Double] {
        switch (item.question, answer) {
        case (.binary, .binary(let probability)):
            return [1 - probability, probability]
        case (.choice(_, let options), .choice(_, let probabilityByName, _)):
            return try options.map { option in
                guard let probability = probabilityByName[option.name] else {
                    throw DecisionSlotTestError.missingOption(item: item.id, option: option.name)
                }
                return probability
            }
        case (.score, .score(_, let levelProbabilities, _, _)):
            return levelProbabilities
        case (.binary, _), (.choice, _), (.score, _):
            throw DecisionSlotTestError.answerKindMismatch(item: item.id)
        }
    }

    /// The probability of "yes" of a yes/no answer.
    ///
    /// - Parameters:
    ///   - answer: The answer.
    ///   - item: The yes/no item that the answer is for.
    /// - Returns: The probability of "yes".
    /// - Throws: ``DecisionSlotTestError/answerKindMismatch(item:)`` when the
    ///   answer is not a yes/no answer.
    static func yesProbability(of answer: Answer, for item: DeciderReferenceItem) throws -> Double {
        guard case .binary(let probability) = answer else {
            throw DecisionSlotTestError.answerKindMismatch(item: item.id)
        }
        return probability
    }

    /// Answers ``flashPrompt`` on the flash model of `profile`, and asks the
    /// question of `item` on the decision slot while that generation runs.
    ///
    /// The question starts after the first text or reasoning delta of the
    /// generation, so the generation is in progress when the decision starts.
    /// The stream keeps each later event, so the generation continues while
    /// the decision runs.
    ///
    /// - Parameters:
    ///   - item: The item to ask.
    ///   - profile: The resolved profile.
    /// - Returns: The answer of the decision, and the events of the generation
    ///   that came after the decision started.
    /// - Throws: The error of the generation or of the decision.
    static func decideDuringGeneration(
        _ item: DeciderReferenceItem, on profile: LanguageModelProfile
    ) async throws -> (answer: Answer, laterEvents: [SessionEvent]) {
        let session = profile.flash.makeSession(instructions: flashInstructions)
        var events = await session.streamEvents(to: flashPrompt, maxTokens: flashAnswerTokenCeiling)
            .makeAsyncIterator()
        var generationStarted = false
        while !generationStarted, let event = try await events.next() {
            generationStarted = event.isGenerationDelta
        }
        let answer = try await ask(item, on: profile.decision)
        var laterEvents: [SessionEvent] = []
        while let event = try await events.next() {
            laterEvents.append(event)
        }
        return (answer, laterEvents)
    }
}

extension SessionEvent {
    /// Whether the event is a text delta or a reasoning delta of a generation.
    fileprivate var isGenerationDelta: Bool {
        switch self {
        case .textDelta, .reasoningDelta: true
        default: false
        }
    }

    /// Whether the event is the end of an answer that succeeded.
    fileprivate var isAnswered: Bool {
        if case .answered = self { true } else { false }
    }
}

// MARK: - Suite

/// Gated real-model coverage of the decision slot of a profile through
/// `Router.resolve` (task ^3mpxfe5): the `decider-2b` model wins the slot and
/// gives the answers of the Metal reference, and a profile with no decision
/// candidate answers on its flash model.
///
/// ## What it proves
///
/// 1. A profile whose decision slot names ``deciderModel`` resolves with that
///    model in the slot. The format of the slot is `DeciderPromptFormat`, from
///    the `decider_config.json` file that the metadata source read. One item
///    of each kind of question gives the top answer of the reference, with
///    each probability near the reference.
/// 2. A profile whose decision slot names no candidate uses the flash model
///    with `GenericPromptFormat`, and a clear yes/no question gets the
///    correct answer.
/// 3. In that fallback, a decision while a generation runs on the same
///    llama.cpp model finishes, and the generation finishes too: the lock of
///    the llama.cpp model serializes the two.
///
/// ## What each resolve loads
///
/// `Router.resolve(profile:reporting:)` fills all four slots, so each resolve
/// loads ``standardModel``, ``flashModel`` and ``RealModels/embedding``, and
/// the first test also loads ``deciderModel``. All four models are small.
///
/// ## Teardown
///
/// Each test drops its profile and waits until its pool has no resident
/// model.
///
/// The suite has no time limit. A run ends when it ends, or when the caller
/// stops it.
@Suite(
    "Gated real-model coverage: the decision slot resolves and decides",
    .serialized,
    .exclusiveRealModel
)
struct DecisionSlotIntegrationTests {
    /// The router of each test, over a pool of its own.
    private let fixture = IsolatedPoolRouter(label: "DecisionSlotIntegrationTests", samplingMode: decisionSamplingMode)

    @Test("the decider wins the decision slot and gives the answers of the Metal reference")
    func deciderGivesTheReferenceAnswers() async throws {
        defer { fixture.removeRoot() }

        try await fixture.withResolved(deciderProfile) { profile in
            #expect(profile.decision.chosen == deciderModel)
            #expect(try DecisionSlotProbe.format(of: profile) is DeciderPromptFormat)
            for item in deciderReferenceItems {
                let answer = try await DecisionSlotProbe.ask(item, on: profile.decision)
                let probabilities = try DecisionSlotProbe.probabilities(of: answer, for: item)
                try #require(probabilities.count == item.probabilities.count, "\(item.id): \(probabilities)")
                let top = probabilities.indices.max { probabilities[$0] < probabilities[$1] }
                #expect(top == item.topIndex, "\(item.id): \(probabilities)")
                let largestDifference = zip(probabilities, item.probabilities).map { abs($0 - $1) }.max() ?? 0
                #expect(largestDifference <= referenceProbabilityTolerance, "\(item.id): \(probabilities)")
            }
        }
    }

    @Test("a profile with no decision candidate decides on its flash model")
    func flashFallbackDecides() async throws {
        defer { fixture.removeRoot() }

        try await fixture.withResolved(flashFallbackProfile) { profile in
            #expect(profile.decision.chosen == profile.flash.chosen)
            #expect(try DecisionSlotProbe.format(of: profile) is GenericPromptFormat)
            let answer = try await DecisionSlotProbe.ask(invoicePaidItem, on: profile.decision)
            #expect(try DecisionSlotProbe.yesProbability(of: answer, for: invoicePaidItem) >= binaryYesThreshold)
        }
    }

    @Test("a fallback decision while a flash generation runs finishes, and the generation finishes")
    func fallbackDecisionDuringGenerationFinishes() async throws {
        defer { fixture.removeRoot() }

        let (answer, laterEvents) = try await fixture.withResolved(flashFallbackProfile) { profile in
            try await DecisionSlotProbe.decideDuringGeneration(invoicePaidItem, on: profile)
        }

        #expect(try DecisionSlotProbe.yesProbability(of: answer, for: invoicePaidItem) >= binaryYesThreshold)
        #expect(laterEvents.contains { $0.isAnswered }, "events after the decision: \(laterEvents)")
    }
}
