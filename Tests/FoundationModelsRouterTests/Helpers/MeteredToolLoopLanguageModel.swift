import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// The usage one generation call of a ``MeteredToolLoopLanguageModel``
/// reports.
struct MeteredGenerationCall: Sendable, Hashable {
    /// The input token count the call reports.
    let tokensIn: Int

    /// The output token count the call reports.
    let tokensOut: Int
}

/// A deterministic `LanguageModel` that makes one generation call for each
/// entry of ``calls``, in order. Every call but the last asks for the marker
/// tool. The last call answers with text. Each call reports the usage its
/// entry names, on its own response entry, as the MLX executor reports the
/// usage of one call.
///
/// It carries no generation state of its own: each executor call reads the
/// count of tool rounds out of the transcript it is handed, and that count is
/// the position of the call in ``calls``.
struct MeteredToolLoopLanguageModel: LanguageModel {
    /// The usage of each generation call, in call order.
    let calls: [MeteredGenerationCall]

    /// Declares tool calling, because a tool-mounted session refuses a model
    /// without it.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the scripted calls.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(calls: calls)
    }

    /// The executor that plays out the scripted calls.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// The usage of each generation call, in call order.
            let calls: [MeteredGenerationCall]
        }

        /// The failure a generation call past the end of the script raises.
        struct UnscriptedCall: Error {
            /// The zero-based position of the call the script does not name.
            let callIndex: Int
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = MeteredToolLoopLanguageModel

        /// The answer text the last call sends.
        static let answerText = "The lookups are done."

        /// The name of the tool each call but the last asks for. The session
        /// mounts a ``MarkerEmittingTool`` under it.
        static let toolName = MarkerEmittingTool.toolName

        /// The token count every emitted fragment reports. The usage of a call
        /// comes from its `.updateUsage` action, not from this count.
        private static let emittedTokenCount = 1

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The scripted calls.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// The step name the call at `callIndex` gives the tool as its `value`
        /// argument.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The step name.
        static func toolStep(callIndex: Int) -> String {
            "lookup-\(callIndex)"
        }

        /// The zero-based position of the call `transcript` asks for: the
        /// count of `.toolCalls` entries the earlier calls left in it.
        ///
        /// - Parameter transcript: The transcript this call was handed.
        /// - Returns: The position of the call in the script.
        private static func callIndex(of transcript: Transcript) -> Int {
            transcript.filter { entry in
                if case .toolCalls = entry { return true }
                return false
            }.count
        }

        /// Sends the scripted call at the position `request` asks for.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript this
        ///     call branches on.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: ``UnscriptedCall`` when the SDK asks for a call past the
        ///   end of the script.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: MeteredToolLoopLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = Self.callIndex(of: request.transcript)
            guard callIndex < configuration.calls.count else {
                throw UnscriptedCall(callIndex: callIndex)
            }
            let responseEntryID = "metered-response-\(callIndex)"
            if callIndex == configuration.calls.count - 1 {
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
            } else {
                await channel.send(
                    .toolCalls(
                        entryID: "metered-tool-calls-\(callIndex)",
                        action: .toolCall(
                            id: "metered-call-\(callIndex)",
                            name: Self.toolName,
                            action: .appendArguments(
                                #"{"value":"\#(Self.toolStep(callIndex: callIndex))"}"#,
                                tokenCount: Self.emittedTokenCount))))
            }
            let call = configuration.calls[callIndex]
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: call.tokensIn, cachedTokenCount: 0),
                        output: .init(totalTokenCount: call.tokensOut, reasoningTokenCount: 0))))
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``MeteredToolLoopLanguageModel``, with the tool it mounts, the recorder
/// that holds its run journal, and the directory the router cached into.
struct MeteredToolLoopSessionFixture {
    /// The vended session a test drives its turn on.
    let session: RoutedSession

    /// The tool every call but the last asks for.
    let tool: MarkerEmittingTool

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router, resolves a profile at `context`, and vends a session
    /// over a model that plays out `calls`.
    ///
    /// - Parameters:
    ///   - calls: The usage of each generation call, in call order.
    ///   - context: The working context the profile resolves at.
    ///   - budget: The auto-compaction opt-in of the session, or `nil` (the
    ///     default) for manual compaction only.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        calls: [MeteredGenerationCall],
        context: Int,
        budget: TokenBudget? = nil,
        tempDirPrefix: String
    ) async throws -> MeteredToolLoopSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let tool = MarkerEmittingTool()
        let container = LiveBackendContainer(model: MeteredToolLoopLanguageModel(calls: calls))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        return MeteredToolLoopSessionFixture(
            session: profile.standard.makeSession(tools: [tool], budget: budget),
            tool: tool,
            recorder: recorder,
            directory: directory)
    }
}
