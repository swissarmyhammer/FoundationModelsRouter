import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterRealModelSupport
import Synchronization

/// A ``PooledLogits`` stub with no model. The decision tests put it in a
/// ``ModelPool`` with a stub loader, and wrap it in a stub `LanguageModel`.
///
/// The tokenizer gives one new token ID to each distinct text, and the same
/// ID each time it sees that text again. The empty text gives no token. Thus
/// each label variant of a decision format is one token, and two labels never
/// share a token.
///
/// The chat template renders each message in the ChatML layout, then opens
/// the assistant message with one of two fixed texts: one for
/// `reasoning: false` and one for `reasoning: true`. The log probability of a
/// candidate after a prompt comes from the candidate and the prompt. Thus each
/// result depends on the arguments of its call, and a test sees when a caller
/// forwards the wrong arguments. The stub counts the calls of
/// ``logProbabilities(of:after:)``.
final class StubLogits: PooledLogits {
    /// The text that starts each message.
    private static let messageStart = "<|im_start|>"

    /// The text that ends each message.
    private static let messageEnd = "<|im_end|>\n"

    /// The role of the message that the template opens at the end.
    private static let assistantRole = "assistant"

    /// The text after the assistant message start, for `reasoning: false`.
    let reasoningOffSuffix: String

    /// The text after the assistant message start, for `reasoning: true`.
    let reasoningOnSuffix: String

    /// The prompt limit that the stub gives.
    let maximumPromptTokens: Int?

    /// The token ID of each text that the stub saw, and the count of the
    /// ``logProbabilities(of:after:)`` calls.
    private let state = Mutex((vocabulary: [String: Int](), logProbabilityCalls: 0))

    /// Makes a stub.
    ///
    /// - Parameters:
    ///   - reasoningOffSuffix: The text after the assistant message start, for
    ///     `reasoning: false`.
    ///   - reasoningOnSuffix: The text after the assistant message start, for
    ///     `reasoning: true`.
    ///   - maximumPromptTokens: The prompt limit, or `nil` for no limit.
    init(reasoningOffSuffix: String, reasoningOnSuffix: String, maximumPromptTokens: Int? = nil) {
        self.reasoningOffSuffix = reasoningOffSuffix
        self.reasoningOnSuffix = reasoningOnSuffix
        self.maximumPromptTokens = maximumPromptTokens
    }

    /// The count of the ``logProbabilities(of:after:)`` calls.
    var logProbabilityCallCount: Int { state.withLock { $0.logProbabilityCalls } }

    /// Gives the token ID of `text`: a new ID for a text that the stub did
    /// not see before.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: No token for the empty text, else one token.
    func tokenize(_ text: String) async throws -> [Int] {
        guard !text.isEmpty else { return [] }
        return state.withLock { state in
            let id = state.vocabulary[text] ?? state.vocabulary.count
            state.vocabulary[text] = id
            return [id]
        }
    }

    /// Renders each message in the ChatML layout, then opens the assistant
    /// message with the suffix of `reasoning`.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat, each with a `role` and a
    ///     `content`.
    ///   - reasoning: The reasoning request.
    /// - Returns: The rendered messages, then the assistant message start and
    ///   ``reasoningOnSuffix`` or ``reasoningOffSuffix``.
    func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        let rendered = messages.map { message in
            Self.messageStart + (message["role"] ?? "") + "\n" + (message["content"] ?? "") + Self.messageEnd
        }
        let suffix = reasoning ? reasoningOnSuffix : reasoningOffSuffix
        return rendered.joined() + Self.messageStart + Self.assistantRole + "\n" + suffix
    }

    /// Counts the call and gives, for each prompt, the log probability of each
    /// candidate.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts.
    /// - Returns: One row for each prompt, with one value for each candidate:
    ///   the value of ``logProbability(of:after:)``.
    func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        state.withLock { $0.logProbabilityCalls += 1 }
        return prompts.map { prompt in candidates.map { Self.logProbability(of: $0, after: prompt) } }
    }

    /// Gives the log probability of `candidate` after `prompt`: the negative
    /// of the sum of the candidate and the prompt token IDs. The value is not
    /// more than zero for token IDs that are not negative, and it changes
    /// with each argument.
    ///
    /// - Parameters:
    ///   - candidate: The token ID to read.
    ///   - prompt: The prompt.
    /// - Returns: The log probability.
    private static func logProbability(of candidate: Int, after prompt: [Int]) -> Double {
        -Double(candidate + prompt.reduce(0, +))
    }
}

extension FixedContainerLoader {
    /// Acquires a hold of `ref` as an LLM from a new pool, over `container`.
    ///
    /// - Parameters:
    ///   - container: The container of the hold.
    ///   - ref: The model reference of the hold.
    /// - Returns: The hold.
    /// - Throws: The error of the acquire.
    static func llmHold(over container: any Sendable, ref: ModelRef) async throws -> ModelHold {
        try await ModelPool().acquire(
            ModelPoolKey(ref: ref, role: .llm), footprintBytes: 0, sessionBytes: 0,
            loader: FixedContainerLoader(container: container))
    }
}

/// An executor that runs no generation. The stub models of the decision tests
/// use it: a test reads their logits, never a reply.
struct UndrivenExecutor<Model: FoundationModels.LanguageModel>: LanguageModelExecutor {
    /// The executor cache key. The executor keeps no state, thus all keys are
    /// equal.
    struct Configuration: Sendable, Hashable {}

    /// The error of each generation.
    enum UndrivenError: Error {
        /// A test asked the stub model for a reply.
        case generationNotSupported
    }

    /// Makes the executor.
    ///
    /// - Parameter configuration: The cache key. Unread.
    init(configuration: Configuration) {}

    /// Throws ``UndrivenError/generationNotSupported`` and generates nothing.
    ///
    /// - Parameters:
    ///   - request: The generation request. Unread.
    ///   - model: The stub model. Unread.
    ///   - channel: The generation channel. Unread.
    /// - Throws: ``UndrivenError/generationNotSupported``, always.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        throw UndrivenError.generationNotSupported
    }
}

/// A `LanguageModel` that does not conform to ``PooledLogits``.
struct PlainStubLanguageModel: FoundationModels.LanguageModel {
    /// No capabilities.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor, which runs no generation.
    typealias Executor = UndrivenExecutor<PlainStubLanguageModel>

    /// The one cache key of the executor.
    var executorConfiguration: Executor.Configuration { .init() }
}

/// A `LanguageModel` that conforms to ``PooledLogits``. Each logits call goes
/// to ``logits``.
struct LogitsStubLanguageModel: FoundationModels.LanguageModel, PooledLogits {
    /// The stub that answers each logits call.
    let logits: StubLogits

    /// No capabilities.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor, which runs no generation.
    typealias Executor = UndrivenExecutor<LogitsStubLanguageModel>

    /// The one cache key of the executor.
    var executorConfiguration: Executor.Configuration { .init() }

    /// The prompt limit of ``logits``.
    var maximumPromptTokens: Int? { logits.maximumPromptTokens }

    /// Tokenizes with ``logits``.
    ///
    /// - Parameter text: The text to tokenize.
    /// - Returns: The tokens that ``logits`` gives.
    func tokenize(_ text: String) async throws -> [Int] {
        try await logits.tokenize(text)
    }

    /// Renders with ``logits``.
    ///
    /// - Parameters:
    ///   - messages: The messages of the chat.
    ///   - reasoning: The reasoning request.
    /// - Returns: The text that ``logits`` gives.
    func renderChatTemplate(_ messages: [[String: String]], reasoning: Bool) async throws -> String? {
        try await logits.renderChatTemplate(messages, reasoning: reasoning)
    }

    /// Reads the log probabilities from ``logits``.
    ///
    /// - Parameters:
    ///   - candidates: The token IDs to read.
    ///   - prompts: The prompts.
    /// - Returns: The rows that ``logits`` gives.
    func logProbabilities(of candidates: [Int], after prompts: [[Int]]) async throws -> [[Double]] {
        try await logits.logProbabilities(of: candidates, after: prompts)
    }
}
