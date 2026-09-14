import Foundation
import FoundationModels
import Synchronization

@testable import FoundationModelsRouter

/// The token ceilings a ``CeilingProbeLanguageModel`` was asked to generate
/// under, one for each generation call, in call order.
///
/// A class behind a lock, because the SDK generates on a task of its own while
/// the test reads the log on the task that drove the turn. It is `Hashable` by
/// identity, so it can be part of the executor cache key.
final class CeilingProbeLog: Sendable, Hashable {
    /// The ceilings seen so far. `nil` is a call that named no ceiling.
    private let ceilings: Mutex<[Int?]> = Mutex([])

    /// The `maximumResponseTokens` of each generation call, in call order.
    var requestedCeilings: [Int?] { ceilings.withLock { $0 } }

    /// Records the ceiling of one generation call.
    ///
    /// - Parameter ceiling: The `maximumResponseTokens` the call carried.
    /// - Returns: The zero-based position of this call in the log.
    func record(ceiling: Int?) -> Int {
        ceilings.withLock { ceilings in
            ceilings.append(ceiling)
            return ceilings.count - 1
        }
    }

    /// Two logs are equal only when they are the same log.
    static func == (lhs: CeilingProbeLog, rhs: CeilingProbeLog) -> Bool {
        lhs === rhs
    }

    /// Hashes the identity of the log.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// How one generation call of a ``CeilingProbeLanguageModel`` ends.
enum CeilingProbeCallEnding: Sendable, Hashable {
    /// The model closes its thought and gives a short answer.
    case finished

    /// The model runs out of budget inside its thought. The executor then
    /// sends the `incompleteOutput` metadata the MLX executor sends.
    case truncatedInsideReasoning

    /// The model closes its thought and runs out of budget inside its answer
    /// text. The executor sends part of the answer and a usage whose output is
    /// equal to the ceiling, and no metadata, as the unconstrained MLX path does.
    case truncatedInAnswerText

    /// The model says a short narration, calls
    /// ``CeilingProbeLanguageModel/Executor/toolName``, and sends a usage whose
    /// output is equal to the ceiling. The SDK then runs the tool and makes one
    /// more generation call in the same attempt.
    case callsTool

    /// The model closes its thought and sends no answer text and no usage.
    /// The executor sends only the model id metadata the MLX executor sends
    /// at the start of each call, so the call still has a response entry.
    case endsWithoutText
}

/// How a ``CeilingProbeLanguageModel`` ends each generation call.
enum CeilingProbeEnding: Sendable, Hashable {
    /// Each call ends as ``CeilingProbeCallEnding/finished``.
    case finished

    /// Each call ends as ``CeilingProbeCallEnding/truncatedInsideReasoning``.
    case truncatedInsideReasoning

    /// Each call ends as ``CeilingProbeCallEnding/truncatedInAnswerText``.
    case truncatedInAnswerText

    /// The first generation call ends as ``truncatedInsideReasoning``, and
    /// each later call ends as ``finished``.
    case truncatedOnFirstCallOnly

    /// The first generation call ends as ``CeilingProbeCallEnding/callsTool``,
    /// and each later call ends as ``truncatedInAnswerText``.
    case toolCallThenTruncatedInAnswerText

    /// The first generation call ends as ``CeilingProbeCallEnding/callsTool``,
    /// and each later call ends as ``finished``.
    case toolCallThenFinished

    /// The first generation call ends as ``CeilingProbeCallEnding/callsTool``,
    /// and each later call ends as ``CeilingProbeCallEnding/endsWithoutText``.
    case toolCallThenNoText

    /// How the call at `callIndex` ends.
    ///
    /// - Parameter callIndex: The zero-based position of the call in the log.
    /// - Returns: The ending of that one call.
    func callEnding(callIndex: Int) -> CeilingProbeCallEnding {
        switch self {
        case .finished:
            return .finished
        case .truncatedInsideReasoning:
            return .truncatedInsideReasoning
        case .truncatedInAnswerText:
            return .truncatedInAnswerText
        case .truncatedOnFirstCallOnly:
            return callIndex == 0 ? .truncatedInsideReasoning : .finished
        case .toolCallThenTruncatedInAnswerText:
            return callIndex == 0 ? .callsTool : .truncatedInAnswerText
        case .toolCallThenFinished:
            return callIndex == 0 ? .callsTool : .finished
        case .toolCallThenNoText:
            return callIndex == 0 ? .callsTool : .endsWithoutText
        }
    }
}

/// A deterministic `LanguageModel` that records the ceiling of each call and
/// ends the call as ``CeilingProbeEnding`` says.
///
/// Each truncated ending sends the same channel actions as the MLX executor of
/// `MLXFoundationModels`. When generation stops inside a reasoning block, the
/// call sends reasoning text, then `["incompleteOutput": true]` as metadata on
/// the response entry, with no response text. When generation stops inside the
/// answer text, the call sends reasoning text, part of the answer, and a usage
/// whose output is equal to the ceiling, with no metadata. A call that asks for
/// a tool sends the tool call and then its usage on the response entry, as the
/// allowed tool path of the MLX executor does.
struct CeilingProbeLanguageModel: LanguageModel {
    /// How each generation call ends.
    let ending: CeilingProbeEnding

    /// The log each generation call writes its ceiling into.
    let log: CeilingProbeLog

    /// Declares reasoning, because the executor sends a reasoning entry, and
    /// tool calling, because a tool-mounted session refuses a model without it.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning, .toolCalling]) }

    /// Builds the executor cache key from the ending and the log.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(ending: ending, log: log)
    }

    /// The executor that records the ceiling and plays out the ending.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// How each generation call ends.
            let ending: CeilingProbeEnding

            /// The log to write each ceiling into.
            let log: CeilingProbeLog
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = CeilingProbeLanguageModel

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The reasoning text each call sends before it ends.
        private static let reasoningText = "Let me think about the whole problem before I"

        /// The answer text a finished call sends.
        static let answerText = "The answer is ready."

        /// The part of the answer a call sends before the budget ends in its
        /// answer text.
        static let truncatedAnswerText = "The answer is"

        /// The input token count a truncated call reports in its usage.
        private static let reportedInputTokens = 1

        /// The name of the tool a ``CeilingProbeCallEnding/callsTool`` call
        /// asks for. The session mounts a ``MarkerEmittingTool`` under it.
        static let toolName = MarkerEmittingTool.toolName

        /// The step name a ``CeilingProbeCallEnding/callsTool`` call gives the
        /// tool as its `value` argument.
        static let toolStep = "look-up"

        /// The answer text a ``CeilingProbeCallEnding/callsTool`` call sends
        /// before it asks for the tool.
        private static let narrationText = "Let me look that up."

        /// The id of the one tool call a ``CeilingProbeCallEnding/callsTool``
        /// call sends.
        private static let toolCallID = "ceiling-probe-call"

        /// The tool-calls entry id the call at `callIndex` sends its call under.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The entry id.
        private static func toolCallsEntryID(callIndex: Int) -> String {
            "ceiling-probe-tool-calls-\(callIndex)"
        }

        /// The output token count a call reports when it spends its whole
        /// ceiling.
        ///
        /// - Parameter ceiling: The `maximumResponseTokens` of the call, or
        ///   `nil` for ``MLXFoundationModelsSessionBackend/responseTokenFloor``.
        /// - Returns: The ceiling the backend applied to the call.
        private static func spentCeiling(_ ceiling: Int?) -> Int {
            ceiling ?? MLXFoundationModelsSessionBackend.responseTokenFloor
        }

        /// Sends one usage whose output is equal to the ceiling of the call.
        ///
        /// - Parameters:
        ///   - ceiling: The `maximumResponseTokens` of the call, or `nil`.
        ///   - entryID: The response entry id of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendUsageSpendingCeiling(
            _ ceiling: Int?,
            entryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(
                    entryID: entryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: reportedInputTokens, cachedTokenCount: 0),
                        output: .init(totalTokenCount: spentCeiling(ceiling), reasoningTokenCount: emittedTokenCount))))
        }

        /// The response entry id the call at `callIndex` sends its answer or
        /// its metadata under. Each call gets its own id, as each MLX call does.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The entry id.
        private static func responseEntryID(callIndex: Int) -> String {
            "ceiling-probe-response-\(callIndex)"
        }

        /// The reasoning entry id the call at `callIndex` sends its thought under.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The entry id.
        private static func reasoningEntryID(callIndex: Int) -> String {
            "ceiling-probe-reasoning-\(callIndex)"
        }

        /// The metadata key the MLX executor sends when the budget ends inside
        /// a thought. Spelled here as the upstream literal, so the test proves
        /// the wire contract and not a shared constant.
        private static let incompleteOutputKey = "incompleteOutput"

        /// The metadata key the MLX executor sends the model id under at the
        /// start of each call.
        private static let modelIDKey = "modelID"

        /// The model id a ``CeilingProbeCallEnding/endsWithoutText`` call sends.
        private static let modelID = "ceiling-probe"

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The ending and the log.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the ceiling, sends the thought, and ends the call.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the ceiling.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: CeilingProbeLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = configuration.log.record(ceiling: request.generationOptions.maximumResponseTokens)
            await channel.send(
                .reasoning(
                    entryID: Self.reasoningEntryID(callIndex: callIndex),
                    action: .appendText(Self.reasoningText, tokenCount: Self.emittedTokenCount)))
            let responseEntryID = Self.responseEntryID(callIndex: callIndex)
            switch configuration.ending.callEnding(callIndex: callIndex) {
            case .finished:
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
            case .truncatedInsideReasoning:
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .updateMetadata([Self.incompleteOutputKey: true])))
            case .truncatedInAnswerText:
                await Self.sendAnswerTruncatedAtCeiling(
                    request.generationOptions.maximumResponseTokens, entryID: responseEntryID, into: channel)
            case .callsTool:
                await Self.sendToolCallSpendingCeiling(
                    request.generationOptions.maximumResponseTokens, callIndex: callIndex, into: channel)
            case .endsWithoutText:
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .updateMetadata([Self.modelIDKey: Self.modelID])))
            }
        }

        /// Sends part of the answer, then one usage whose output is equal to
        /// `ceiling`, and no metadata.
        ///
        /// The unconstrained MLX path stops when the count of generated tokens
        /// is equal to the ceiling, and then sends that count as the usage of
        /// the call.
        ///
        /// - Parameters:
        ///   - ceiling: The `maximumResponseTokens` of the call, or `nil` for
        ///     ``MLXFoundationModelsSessionBackend/responseTokenFloor``.
        ///   - entryID: The response entry id of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendAnswerTruncatedAtCeiling(
            _ ceiling: Int?,
            entryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(
                    entryID: entryID,
                    action: .appendText(truncatedAnswerText, tokenCount: emittedTokenCount)))
            await sendUsageSpendingCeiling(ceiling, entryID: entryID, into: channel)
        }

        /// Sends a short narration, one call to ``toolName``, and then one
        /// usage whose output is equal to `ceiling`.
        ///
        /// The allowed tool path of the MLX executor sends the tool call and
        /// then the usage of the call on the response entry id. The usage here
        /// spends the whole ceiling, so the summed output of the attempt
        /// reaches the ceiling whatever the later call spends.
        ///
        /// - Parameters:
        ///   - ceiling: The `maximumResponseTokens` of the call, or `nil` for
        ///     ``MLXFoundationModelsSessionBackend/responseTokenFloor``.
        ///   - callIndex: The zero-based position of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendToolCallSpendingCeiling(
            _ ceiling: Int?,
            callIndex: Int,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            let entryID = responseEntryID(callIndex: callIndex)
            await channel.send(
                .response(entryID: entryID, action: .appendText(narrationText, tokenCount: emittedTokenCount)))
            await channel.send(
                .toolCalls(
                    entryID: toolCallsEntryID(callIndex: callIndex),
                    action: .toolCall(
                        id: toolCallID,
                        name: toolName,
                        action: .appendArguments(#"{"value":"\#(toolStep)"}"#, tokenCount: emittedTokenCount))))
            await sendUsageSpendingCeiling(ceiling, entryID: entryID, into: channel)
        }
    }
}

/// A ``LoadedLLMContainer`` that vends the production
/// ``MLXFoundationModelsSessionBackend`` over a ``CeilingProbeLanguageModel``,
/// so a routed session drives the real backend with no GPU.
struct CeilingProbeContainer: LoadedLLMContainer {
    /// The probe model every backend of this container runs over.
    let model: CeilingProbeLanguageModel

    /// Vends a backend over a fresh session carrying `instructions`, with no
    /// tools mounted.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A live backend over ``model``.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Vends a backend over a fresh session carrying `instructions`, with
    /// `tools` mounted so a ``CeilingProbeCallEnding/callsTool`` call can call
    /// them. The protocol default drops the tools.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A live backend over ``model``.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            session: LanguageModelSession(model: model, tools: tools, instructions: instructions),
            model: model,
            instructions: instructions,
            tools: tools)
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with no
    /// tools mounted.
    ///
    /// - Parameter transcript: The transcript to seed the session from.
    /// - Returns: A live backend over ``model``.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with
    /// `tools` mounted.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the session from.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A live backend over ``model``.
    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            session: LanguageModelSession(model: model, tools: tools, transcript: transcript),
            model: model,
            instructions: TranscriptDiffer.leadingInstructionsText(of: transcript),
            tools: tools)
    }
}

/// A routed session over a ``CeilingProbeContainer``, with the log its model
/// writes into and the directory the router cached into.
struct CeilingProbeSessionFixture {
    /// The vended session a test drives its turn on.
    let session: RoutedSession

    /// The log of the ceiling of each generation call.
    let log: CeilingProbeLog

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router, resolves a profile at `context`, and vends a session
    /// over a probe model that ends each call as `ending` says.
    ///
    /// - Parameters:
    ///   - ending: How each generation call ends.
    ///   - context: The working context the profile resolves at.
    ///   - tools: The tools the session mounts.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The session, its log, and the temp directory.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        ending: CeilingProbeEnding,
        context: Int = ProfileDefinition.defaultContext,
        tools: [any Tool] = [],
        tempDirPrefix: String
    ) async throws -> CeilingProbeSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = CeilingProbeLog()
        let container = CeilingProbeContainer(model: CeilingProbeLanguageModel(ending: ending, log: log))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        return CeilingProbeSessionFixture(
            session: profile.standard.makeSession(tools: tools), log: log, directory: directory)
    }
}
