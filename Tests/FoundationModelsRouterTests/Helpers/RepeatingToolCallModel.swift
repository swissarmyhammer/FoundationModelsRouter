import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// The arguments of the `runCode` tool: one snippet of code.
@Generable
struct RunCodeArguments {
    /// The code to run.
    let code: String
}

/// A `runCode` tool that counts its runs and runs nothing else
/// (task ^dzw15st).
struct CountingRunCodeTool: Tool {
    /// The name the scripted model calls.
    static let toolName = "runCode"

    /// The output of each run.
    static let output = "the code ran"

    /// The name the scripted model calls.
    let name = Self.toolName

    /// The description the model reads.
    let description = "Runs one snippet of code."

    /// The count of the runs of this tool.
    let runs: RunCount

    /// Counts one run and gives ``output``.
    ///
    /// - Parameter arguments: The snippet. Unread.
    /// - Returns: ``output``.
    func call(arguments: RunCodeArguments) async throws -> String {
        runs.increment()
        return Self.output
    }
}

/// A count that a tool body writes and a test reads.
final class RunCount: Sendable {
    /// The count so far.
    private let count = Mutex(0)

    /// The count so far.
    var value: Int { count.withLock { $0 } }

    /// Adds one to the count.
    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// A deterministic `LanguageModel` whose first call asks for one `runCode`
/// tool call with a scripted snippet (task ^dzw15st).
///
/// Each executor call records the transcript it receives in ``log``, then:
///
/// - a call whose transcript holds a tool output, and a call whose prompt is
///   ``RoutedSessionActor/repetitionStopContinuationPrompt``, answers with
///   ``Executor/answerText``;
/// - every other call streams one `runCode` tool call. The arguments are the
///   JSON object `{"code": "<snippet>"}`, where each line of the snippet ends
///   with a `\n` escape. Each line goes to the channel as one
///   `appendArguments` action.
struct RepeatingToolCallModel: LanguageModel {
    /// The log that records the transcript of each call.
    let log: RenderProbeLog

    /// The lines of the snippet, in order.
    let snippetLines: [String]

    /// Declares tool calling, which a session with tools needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the log and the snippet.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, snippetLines: snippetLines)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records the transcript of each call.
            let log: RenderProbeLog

            /// The lines of the snippet, in order.
            let snippetLines: [String]

            /// Identity equality on the log, value equality on the snippet.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log and snippet.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.snippetLines == rhs.snippetLines
            }

            /// Hashes the identity of the log and the snippet.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(snippetLines)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = RepeatingToolCallModel

        /// The answer text of a call that ends.
        static let answerText = "The answer, after the tool call."

        /// The id of the one tool call.
        static let toolCallId = "run-code-call"

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The start of the arguments, up to the open snippet string.
        private static let argumentsOpening = #"{"code": ""#

        /// The end of the arguments, from the close of the snippet string.
        private static let argumentsClosing = #""}"#

        /// The JSON escape of a line feed inside a string value.
        private static let escapedLineFeed = #"\n"#

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log and the snippet.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Plays out the call that `request` asks for.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript this
        ///     call branches on.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `CancellationError` when the session stops the call.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: RepeatingToolCallModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(render: request.transcript)
            guard Self.asksForToolCall(request.transcript) else {
                await channel.send(.response(action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
                return
            }
            for fragment in Self.argumentFragments(of: configuration.snippetLines) {
                try Task.checkCancellation()
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: Self.toolCallId, name: CountingRunCodeTool.toolName,
                            action: .appendArguments(fragment, tokenCount: Self.emittedTokenCount))))
            }
        }

        /// Whether a call over `transcript` asks for the tool call: the
        /// transcript holds no tool output, and its last prompt is not the
        /// continuation prompt of a repetition stop.
        ///
        /// - Parameter transcript: The transcript of the call.
        /// - Returns: `true` when the call streams the tool call.
        private static func asksForToolCall(_ transcript: Transcript) -> Bool {
            let holdsToolOutput = transcript.contains { entry in
                guard case .toolOutput = entry else { return false }
                return true
            }
            let isContinuation = transcript.promptTexts.last == RoutedSessionActor.repetitionStopContinuationPrompt
            return !holdsToolOutput && !isContinuation
        }

        /// The arguments of the tool call, in the fragments the call streams:
        /// the opening, one fragment for each line with its `\n` escape, and
        /// the closing. Each line is escaped as the content of a JSON string.
        ///
        /// - Parameter lines: The lines of the snippet.
        /// - Returns: The fragments, in order.
        static func argumentFragments(of lines: [String]) -> [String] {
            [argumentsOpening] + lines.map { jsonStringContent(of: $0) + escapedLineFeed } + [argumentsClosing]
        }

        /// `line` as the content of a JSON string: each backslash and each
        /// quote gets its escape.
        ///
        /// - Parameter line: One line of the snippet.
        /// - Returns: The escaped line.
        private static func jsonStringContent(of line: String) -> String {
            line.replacingOccurrences(of: #"\"#, with: #"\\"#).replacingOccurrences(of: #"""#, with: #"\""#)
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``RepeatingToolCallModel`` with one ``CountingRunCodeTool`` mounted.
struct RepeatingToolCallSessionFixture {
    /// The vended session a test drives its answers on.
    let session: RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The count of the runs of the mounted tool.
    let runs: RunCount

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router and vends a session over a ``RepeatingToolCallModel``
    /// with the default ``RepetitionDetection``.
    ///
    /// - Parameters:
    ///   - snippetLines: The lines of the snippet the model sends.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(snippetLines: [String], tempDirPrefix: String) async throws -> RepeatingToolCallSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = RenderProbeLog()
        let runs = RunCount()
        let model = RepeatingToolCallModel(log: log, snippetLines: snippetLines)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: [CountingRunCodeTool(runs: runs)], repetitionDetection: RepetitionDetection()))
        return RepeatingToolCallSessionFixture(session: session, log: log, runs: runs, directory: directory)
    }
}
