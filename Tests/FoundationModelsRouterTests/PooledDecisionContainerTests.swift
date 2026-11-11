import Foundation
import FoundationModels
import FoundationModelsDecision
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of ``PooledDecisionContainer`` over a hold of a stub pool, and of
/// the ``PooledLogits`` conformance of ``LiveLLMContainer``. No test
/// downloads or loads a model.
@Suite("The decision container and the logits of the live container")
struct PooledDecisionContainerTests {
    // MARK: - Fixed values

    /// The model reference of each hold.
    private static let ref: ModelRef = "org/decision-stub"

    /// The start of an assistant message that turns reasoning off: the
    /// thinking block is closed.
    private static let closedThinkingSuffix = "<think>\n\n</think>\n\n"

    /// The start of an assistant message that turns reasoning on: the
    /// thinking block is open at the end.
    private static let openThinkingSuffix = "<think>\n"

    /// The prompt limits of the stub in the prompt-limit test. Each limit is
    /// different from ``contextWindow``. The `nil` limit is the stub with no
    /// fixed limit.
    private static let promptLimits: [Int?] = [512, 2048, nil]

    /// The context window of each live container. It is different from each
    /// prompt limit, thus a container that gives its context window as the
    /// prompt limit fails a test.
    private static let contextWindow = 4096

    /// The text of the tokenize test of a plain model.
    private static let text = "some text"

    /// The texts of the tokenize forwarding test. The stub gives a different
    /// result for each text: no token for the empty text, and a different
    /// token for each other text.
    private static let texts = ["", text, "other text"]

    /// The reasoning requests of the render forwarding test.
    private static let reasoningRequests = [false, true]

    /// The candidate token IDs of the log-probability tests.
    private static let candidates = [3, 5]

    /// The prompts of the log-probability tests.
    private static let prompts = [[1, 2], [4]]

    /// The messages of the render tests.
    private static let messages = [["role": "user", "content": "question"]]

    /// The yes-or-no question of the decision tests.
    private static let question = "Is the state urgent?"

    /// The state of the decision tests.
    private static let state: DecisionState = "The server is down."

    // MARK: - Helpers

    /// Makes a stub whose chat template opens the assistant message with
    /// `reasoningOffSuffix` for `reasoning: false`, and with an open thinking
    /// block for `reasoning: true`.
    ///
    /// - Parameters:
    ///   - reasoningOffSuffix: The start of the assistant message for
    ///     `reasoning: false`.
    ///   - maximumPromptTokens: The prompt limit of the stub.
    /// - Returns: The stub.
    private static func makeLogits(
        reasoningOffSuffix: String = closedThinkingSuffix, maximumPromptTokens: Int? = nil
    ) -> StubLogits {
        StubLogits(
            reasoningOffSuffix: reasoningOffSuffix, reasoningOnSuffix: openThinkingSuffix,
            maximumPromptTokens: maximumPromptTokens)
    }

    /// Makes a live container over `model`.
    ///
    /// - Parameter model: The model of the container.
    /// - Returns: The container.
    private static func liveContainer(over model: any FoundationModels.LanguageModel) -> LiveLLMContainer {
        LiveLLMContainer(
            model: model, ref: ref, contextWindow: contextWindow, tokenCounter: CharacterTokenCounter())
    }

    /// Makes a decision session over a container of a hold of `logits`.
    ///
    /// - Parameters:
    ///   - logits: The container of the hold.
    ///   - format: The prompt format of the container.
    /// - Returns: The session.
    /// - Throws: The error of the acquire or of the container.
    private static func makeSession(
        over logits: StubLogits, format: any DecisionPromptFormat = GenericPromptFormat()
    ) async throws -> DecisionSession {
        let hold = try await FixedContainerLoader.llmHold(over: logits, ref: ref)
        let container = try PooledDecisionContainer(hold: hold, format: format)
        return DecisionSession(model: container.decisionModel, state: state)
    }

    /// Tokenizes each text with `source`, in order.
    ///
    /// - Parameters:
    ///   - texts: The texts to tokenize.
    ///   - source: The log-probability source that tokenizes.
    /// - Returns: The tokens of each text, in the order of `texts`.
    /// - Throws: The error of `source`.
    private static func tokenizeEach(_ texts: [String], with source: any PooledLogits) async throws -> [[Int]] {
        var tokens: [[Int]] = []
        for text in texts {
            tokens.append(try await source.tokenize(text))
        }
        return tokens
    }

    // MARK: - The container

    /// The decision model of the container names the model of the hold.
    @Test("the decision model of the container has the ref of the hold as its model ID")
    func decisionModelHasTheRefOfTheHold() async throws {
        let hold = try await FixedContainerLoader.llmHold(over: Self.makeLogits(), ref: Self.ref)
        let container = try PooledDecisionContainer(hold: hold, format: GenericPromptFormat())
        #expect(container.decisionModel.modelID == Self.ref.stringValue)
    }

    /// A hold whose container gives no logits makes no container.
    @Test("a hold whose container is not PooledLogits throws notLogitsCapable")
    func holdWithoutLogitsThrows() async throws {
        let hold = try await FixedContainerLoader.llmHold(over: PlainStubLanguageModel(), ref: Self.ref)
        #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.ref)) {
            try PooledDecisionContainer(hold: hold, format: GenericPromptFormat())
        }
    }

    // MARK: - Reasoning off

    /// A chat template that leaves a thinking block open makes the decision
    /// throw.
    @Test("a template that cannot turn reasoning off makes a decision throw unsupportedModel")
    func openThinkingTemplateThrowsUnsupportedModel() async throws {
        let session = try await Self.makeSession(over: Self.makeLogits(reasoningOffSuffix: Self.openThinkingSuffix))
        await #expect(throws: DecisionError.unsupportedModel(ReasoningOffPromptFormat.openThinkingMessage)) {
            try await session.probability(of: Self.question)
        }
    }

    /// A chat template that leaves a thinking block open gives no
    /// probabilities: the model evaluates no prompt.
    @Test("a template that cannot turn reasoning off gives no probabilities")
    func openThinkingTemplateReadsNoProbabilities() async throws {
        let logits = Self.makeLogits(reasoningOffSuffix: Self.openThinkingSuffix)
        let session = try await Self.makeSession(over: logits)
        await #expect(throws: DecisionError.self) {
            try await session.probability(of: Self.question)
        }
        #expect(logits.logProbabilityCallCount == 0)
    }

    /// A chat template that closes the thinking block gives a decision.
    @Test("a template that turns reasoning off gives probabilities")
    func closedThinkingTemplateReadsProbabilities() async throws {
        let logits = Self.makeLogits()
        let session = try await Self.makeSession(over: logits)
        _ = try await session.probability(of: Self.question)
        #expect(logits.logProbabilityCallCount == 1)
    }

    /// The closed-think fallback of the generic format closes the open block
    /// itself, thus the container accepts the template.
    @Test("the closed-think fallback of the generic format accepts an open thinking block")
    func closedThinkFallbackAcceptsOpenThinkingTemplate() async throws {
        let logits = Self.makeLogits(reasoningOffSuffix: Self.openThinkingSuffix)
        let session = try await Self.makeSession(over: logits, format: GenericPromptFormat(closedThinkFallback: true))
        _ = try await session.probability(of: Self.question)
        #expect(logits.logProbabilityCallCount == 1)
    }

    // MARK: - The logits of the live container

    /// The live container tokenizes each text with a model that gives
    /// logits. The stub gives a different result for each text, thus a
    /// container that does not forward the text fails.
    @Test("the live container forwards tokenize to a logits model")
    func liveContainerForwardsTokenize() async throws {
        let logits = Self.makeLogits()
        let container = Self.liveContainer(over: LogitsStubLanguageModel(logits: logits))
        let tokens = try await Self.tokenizeEach(Self.texts, with: container)
        #expect(tokens == (try await Self.tokenizeEach(Self.texts, with: logits)))
    }

    /// The tokenize forwarding test feeds texts that the stub tells apart.
    @Test("the stub gives a different result for each text of the tokenize forwarding test")
    func stubTokenizesEachTextDifferently() async throws {
        let tokens = try await Self.tokenizeEach(Self.texts, with: Self.makeLogits())
        #expect(Set(tokens).count == Self.texts.count)
    }

    /// The live container renders the chat template of a model that gives
    /// logits, with the reasoning request of the caller.
    @Test(
        "the live container forwards renderChatTemplate with the reasoning request to a logits model",
        arguments: reasoningRequests)
    func liveContainerForwardsRenderChatTemplate(reasoning: Bool) async throws {
        let logits = Self.makeLogits()
        let container = Self.liveContainer(over: LogitsStubLanguageModel(logits: logits))
        let rendered = try await container.renderChatTemplate(Self.messages, reasoning: reasoning)
        #expect(rendered == (try await logits.renderChatTemplate(Self.messages, reasoning: reasoning)))
    }

    /// The render forwarding test feeds reasoning requests that the stub
    /// tells apart, thus a container that drops the request fails.
    @Test("the stub renders a different text for each reasoning request")
    func stubRendersEachReasoningRequestDifferently() async throws {
        let logits = Self.makeLogits()
        let off = try await logits.renderChatTemplate(Self.messages, reasoning: false)
        #expect(off != (try await logits.renderChatTemplate(Self.messages, reasoning: true)))
    }

    /// The live container reads the log probabilities of a model that gives
    /// logits.
    @Test("the live container forwards logProbabilities to a logits model")
    func liveContainerForwardsLogProbabilities() async throws {
        let logits = Self.makeLogits()
        let container = Self.liveContainer(over: LogitsStubLanguageModel(logits: logits))
        let rows = try await container.logProbabilities(of: Self.candidates, after: Self.prompts)
        #expect(rows == (try await logits.logProbabilities(of: Self.candidates, after: Self.prompts)))
    }

    /// The live container gives the prompt limit of a model that gives logits,
    /// also when the model has no fixed limit.
    @Test("the live container forwards maximumPromptTokens to a logits model", arguments: promptLimits)
    func liveContainerForwardsMaximumPromptTokens(promptLimit: Int?) {
        let logits = Self.makeLogits(maximumPromptTokens: promptLimit)
        let container = Self.liveContainer(over: LogitsStubLanguageModel(logits: logits))
        #expect(container.maximumPromptTokens == logits.maximumPromptTokens)
    }

    /// The live container cannot tokenize with a model that gives no logits.
    @Test("the live container throws notLogitsCapable from tokenize for a plain model")
    func liveContainerTokenizeThrowsForPlainModel() async {
        let container = Self.liveContainer(over: PlainStubLanguageModel())
        await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.ref)) {
            try await container.tokenize(Self.text)
        }
    }

    /// The live container cannot render with a model that gives no logits.
    @Test("the live container throws notLogitsCapable from renderChatTemplate for a plain model")
    func liveContainerRenderThrowsForPlainModel() async {
        let container = Self.liveContainer(over: PlainStubLanguageModel())
        await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.ref)) {
            try await container.renderChatTemplate(Self.messages, reasoning: false)
        }
    }

    /// The live container cannot read log probabilities from a model that
    /// gives no logits.
    @Test("the live container throws notLogitsCapable from logProbabilities for a plain model")
    func liveContainerLogProbabilitiesThrowsForPlainModel() async {
        let container = Self.liveContainer(over: PlainStubLanguageModel())
        await #expect(throws: PooledLogitsModelError.notLogitsCapable(Self.ref)) {
            try await container.logProbabilities(of: Self.candidates, after: Self.prompts)
        }
    }

    /// The live container gives no prompt limit for a model that gives no
    /// logits.
    @Test("the live container gives no maximumPromptTokens for a plain model")
    func liveContainerHasNoPromptLimitForPlainModel() {
        let container = Self.liveContainer(over: PlainStubLanguageModel())
        #expect(container.maximumPromptTokens == nil)
    }
}
