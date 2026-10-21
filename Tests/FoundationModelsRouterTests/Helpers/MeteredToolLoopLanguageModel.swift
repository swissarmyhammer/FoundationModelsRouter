import Foundation
import FoundationModels
import Tracing

@testable import FoundationModelsRouter

/// The usage one generation call of a ``MeteredToolLoopLanguageModel``
/// reports.
struct MeteredGenerationCall: Sendable, Hashable {
    /// The input token count the call reports.
    let tokensIn: Int

    /// The output token count the call reports.
    let tokensOut: Int

    /// The part of ``tokensIn`` the call reports its prompt cache reused, as
    /// the MLX executor reports its `cachedTokenCount`.
    var tokensCached: Int = 0

    /// How the call paces its output, or `nil` (the default) for a call that
    /// sends its output at once.
    var pacing: MeteredCallPacing?
}

/// The pace of one generation call of a ``MeteredToolLoopLanguageModel``, as
/// a real model paces a call: it prefills, sends its first output token, and
/// then decodes the rest.
struct MeteredCallPacing: Sendable, Hashable {
    /// The text of the first output token, which the call sends after
    /// ``prefill``. The rest of the output follows after ``decode``.
    static let firstTokenText = "Looking. "

    /// How long the call waits before it sends its first output token.
    let prefill: Duration

    /// How long the call waits after its first output token before it sends
    /// the rest of its output and its usage.
    let decode: Duration

    /// What the first output of the call is.
    var firstOutput: MeteredFirstOutput = .responseText
}

/// What the first output of a paced ``MeteredToolLoopLanguageModel`` call is.
enum MeteredFirstOutput: Sendable, Hashable {
    /// Response text (``MeteredCallPacing/firstTokenText``), then the tool
    /// call or the answer of the call.
    case responseText

    /// The first part of the arguments of the tool call
    /// (``MeteredToolLoopLanguageModel/Executor/argumentsHead``), and the rest
    /// of them after the decode. A call that answers with text sends response
    /// text first, as ``responseText`` does.
    case toolCallArguments

    /// Nothing until the end of the call: the call waits its prefill and its
    /// decode, then sends its whole output at once, as the allowed-tool path
    /// of the MLX executor sends a tool call.
    case nothingUntilTheEnd
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
            // A test failure shows this error through `String(describing:)`, which reads this property by
            // reflection. Periphery cannot see that read.
            // periphery:ignore
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

        /// Waits the prefill of `pacing`, sends the first output token of the
        /// call as response text, and then waits the decode of `pacing`.
        ///
        /// - Parameters:
        ///   - pacing: The pace of the call.
        ///   - entryID: The id of the response entry of the call.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `CancellationError` when the call is cancelled in a wait.
        private static func sendFirstToken(
            after pacing: MeteredCallPacing, entryID: String, into channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await Task.sleep(for: pacing.prefill)
            await channel.send(
                .response(
                    entryID: entryID,
                    action: .appendText(MeteredCallPacing.firstTokenText, tokenCount: emittedTokenCount)))
            try await Task.sleep(for: pacing.decode)
        }

        /// The first part of the arguments of a tool call that streams its
        /// arguments (``MeteredFirstOutput/toolCallArguments``).
        static let argumentsHead = #"{"value":"#

        /// The rest of the arguments of the tool call of the call at
        /// `callIndex`, after ``argumentsHead``.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The rest of the arguments.
        static func argumentsTail(callIndex: Int) -> String {
            #""\#(toolStep(callIndex: callIndex))"}"#
        }

        /// Sends `arguments` as a part of the arguments of the tool call of the
        /// call at `callIndex`.
        ///
        /// - Parameters:
        ///   - arguments: The part of the arguments.
        ///   - callIndex: The zero-based position of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendArguments(
            _ arguments: String, callIndex: Int, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .toolCalls(
                    entryID: "metered-tool-calls-\(callIndex)",
                    action: .toolCall(
                        id: "metered-call-\(callIndex)",
                        name: toolName,
                        action: .appendArguments(arguments, tokenCount: emittedTokenCount))))
        }

        /// Sends the whole output of the call at `callIndex`: the answer text
        /// for the last call, and the tool call for each other call.
        ///
        /// - Parameters:
        ///   - callIndex: The zero-based position of the call.
        ///   - isAnswer: Whether the call is the last call, which answers.
        ///   - responseEntryID: The id of the response entry of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendOutput(
            callIndex: Int, isAnswer: Bool, responseEntryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            guard !isAnswer else {
                await channel.send(
                    .response(
                        entryID: responseEntryID, action: .appendText(answerText, tokenCount: emittedTokenCount)))
                return
            }
            await sendArguments(argumentsHead + argumentsTail(callIndex: callIndex), callIndex: callIndex, into: channel)
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
            let call = configuration.calls[callIndex]
            let isAnswer = callIndex == configuration.calls.count - 1
            switch call.pacing {
            case .some(let pacing) where pacing.firstOutput == .toolCallArguments && !isAnswer:
                try await Task.sleep(for: pacing.prefill)
                await Self.sendArguments(Self.argumentsHead, callIndex: callIndex, into: channel)
                try await Task.sleep(for: pacing.decode)
                await Self.sendArguments(Self.argumentsTail(callIndex: callIndex), callIndex: callIndex, into: channel)
            case .some(let pacing) where pacing.firstOutput == .nothingUntilTheEnd:
                try await Task.sleep(for: pacing.prefill + pacing.decode)
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            case .some(let pacing):
                try await Self.sendFirstToken(after: pacing, entryID: responseEntryID, into: channel)
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            case .none:
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            }
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: call.tokensIn, cachedTokenCount: call.tokensCached),
                        output: .init(totalTokenCount: call.tokensOut, reasoningTokenCount: 0))))
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``MeteredToolLoopLanguageModel``, with the tool it mounts, the recorder
/// that holds its run journal, and the directory the router cached into.
///
/// A test ends the fixture with ``SessionDirectoryFixture/end(opening:)``.
struct MeteredToolLoopSessionFixture: SessionDirectoryFixture {
    /// The vended session a test drives its answer on.
    let session: any RoutedSession

    /// The tool every call but the last asks for.
    let tool: MarkerEmittingTool

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into. ``SessionDirectoryFixture/end(opening:)``
    /// removes it.
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
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws. Before it throws, it
    ///   removes the temp directory.
    static func make(
        calls: [MeteredGenerationCall],
        context: Int,
        budget: TokenBudget? = nil,
        tempDirPrefix: String,
        tracer: (any Tracer)? = nil
    ) async throws -> MeteredToolLoopSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let tool = MarkerEmittingTool()
        let container = LiveBackendContainer(model: MeteredToolLoopLanguageModel(calls: calls))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            tracer: tracer)
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await router.resolve(
                profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        }
        return MeteredToolLoopSessionFixture(
            session: profile.standard.makeSession(tools: [tool], budget: budget),
            tool: tool,
            recorder: recorder,
            directory: directory)
    }
}
