import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A scripted `LanguageModel` that plays a tool loop of a fixed length, and
/// that makes each executor call an observable pass that a test can step.
///
/// A session that mounts a tool gets ``toolRounds`` passes that each call the
/// first mounted tool, and then one pass that answers. A session that mounts
/// no tool gets one pass that answers. Each pass records its prompt in
/// ``passes`` before its first suspension, so the log order is the order in
/// which the passes started. When ``step`` is set, each pass then waits for one
/// signal of that semaphore, so a test releases the passes one at a time and
/// sees which pass the queue admits next.
struct ToolLoopPassModel: LanguageModel {
    /// How many passes of one turn call a tool, in a session that mounts one.
    let toolRounds: Int

    /// The log each pass records into.
    let passes: ObservedPassLog

    /// The semaphore each pass waits on before it emits, or `nil` for passes
    /// that emit at once.
    let step: AsyncSemaphore?

    /// The text an answer opens with.
    static let answerPrefix = "looped: "

    /// The answer the last pass of a turn gives to a prompt.
    ///
    /// - Parameter prompt: The prompt of the turn.
    /// - Returns: The answer text.
    static func answer(to prompt: String) -> String {
        answerPrefix + prompt
    }

    /// Declares tool calling, which a tool-mounted session requires.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// The executor cache key: the loop length and the identities of the log
    /// and the step.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(toolRounds: toolRounds, passes: passes, step: step)
    }

    /// The executor that serves one pass of the loop for each call.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares the reference-typed parts
        /// by identity, because they have no value equality of their own.
        struct Configuration: Sendable, Hashable {
            /// How many passes of one turn call a tool.
            let toolRounds: Int

            /// The log each pass records into.
            let passes: ObservedPassLog

            /// The semaphore each pass waits on, or `nil`.
            let step: AsyncSemaphore?

            /// Equal when the loop lengths are equal and the parts are the
            /// same objects.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both configurations name the same loop.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.toolRounds == rhs.toolRounds && lhs.passes === rhs.passes && lhs.step === rhs.step
            }

            /// Hashes what ``==(_:_:)`` compares.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(toolRounds)
                hasher.combine(ObjectIdentifier(passes))
                hasher.combine(step.map(ObjectIdentifier.init))
            }
        }

        /// The model type this executor serves.
        typealias Model = ToolLoopPassModel

        /// A marker object that gives this executor instance its own identity.
        private final class Identity: Sendable {}

        /// The token count each emitted fragment reports. The model meters
        /// nothing.
        private static let emittedTokenCount = 1

        /// The configuration the SDK built this executor with.
        private let configuration: Configuration

        /// The identity of this executor instance.
        private let identity = Identity()

        /// Stores `configuration`.
        ///
        /// - Parameter configuration: The loop length, the log, and the step.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the pass, waits for its step, and then calls the first
        /// mounted tool or answers the prompt of the turn.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: The model. Unread: the parts arrive through the
        ///     configuration.
        ///   - channel: The channel the pass emits into.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ToolLoopPassModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let turn = Self.currentTurn(of: request.transcript)
            configuration.passes.record(ObservedPass(executor: ObjectIdentifier(identity), prompt: turn.prompt))
            await configuration.step?.wait()
            guard let tool = request.enabledToolDefinitions.first, turn.toolRounds < configuration.toolRounds
            else {
                await channel.send(
                    .response(
                        action: .appendText(ToolLoopPassModel.answer(to: turn.prompt), tokenCount: Self.emittedTokenCount)
                    ))
                return
            }
            let round = "\(turn.prompt)-\(turn.toolRounds)"
            await channel.send(
                .toolCalls(
                    entryID: round,
                    action: .toolCall(
                        id: round,
                        name: tool.name,
                        action: .appendArguments(#"{"value":"\#(round)"}"#, tokenCount: Self.emittedTokenCount))))
        }

        /// The prompt of the turn a transcript ends in, and how many tool
        /// rounds that turn has played so far.
        ///
        /// - Parameter transcript: The transcript of the pass.
        /// - Returns: The joined text of the last `.prompt` entry, and the
        ///   count of `.toolCalls` entries after it.
        private static func currentTurn(of transcript: Transcript) -> (prompt: String, toolRounds: Int) {
            let entries = Array(transcript)
            let lastPromptIndex = entries.lastIndex { entry in
                guard case .prompt = entry else { return false }
                return true
            }
            guard let lastPromptIndex, case .prompt(let prompt) = entries[lastPromptIndex] else {
                return ("", 0)
            }
            let roundsSincePrompt = entries[lastPromptIndex...].filter { entry in
                guard case .toolCalls = entry else { return false }
                return true
            }
            return (WatchedText.text(of: prompt.segments), roundsSincePrompt.count)
        }
    }
}
