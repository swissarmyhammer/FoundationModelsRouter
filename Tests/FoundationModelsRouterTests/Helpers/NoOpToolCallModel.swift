import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A deterministic `LanguageModel` for the no-op tool call stop (task
/// ^rw72f4j). It can start one background job, and then it calls `runCode`
/// one time for each scripted snippet, all in one round.
///
/// Each executor call records the transcript it receives in ``log``, then:
///
/// - a call whose last prompt holds
///   ``RoutedSessionActor/settledRunDeliveryPrompt`` answers with
///   ``Executor/deliveryAnswerText``: the pump delivered the result of the
///   job;
/// - a call of a model that starts a job, whose transcript holds no output of
///   the job tool, streams one call of ``jobToolName``;
/// - a call whose transcript holds no output of `runCode` streams one
///   `runCode` call for each scripted snippet, in one round;
/// - every other call answers with ``Executor/answerText``.
struct NoOpToolCallModel: LanguageModel {
    /// The name of the background tool that the model starts.
    static let jobToolName = "startJob"

    /// The log that records the transcript of each call.
    let log: RenderProbeLog

    /// Whether the first call starts the background job.
    let startsJob: Bool

    /// The snippets of the `runCode` calls of one round, in order.
    let codes: [String]

    /// Declares tool calling, which a session with tools needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the log and the script.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, startsJob: startsJob, codes: codes)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records the transcript of each call.
            let log: RenderProbeLog

            /// Whether the first call starts the background job.
            let startsJob: Bool

            /// The snippets of the `runCode` calls of one round, in order.
            let codes: [String]

            /// Identity equality on the log, value equality on the script.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log and script.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.startsJob == rhs.startsJob && lhs.codes == rhs.codes
            }

            /// Hashes the identity of the log and the script.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(startsJob)
                hasher.combine(codes)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = NoOpToolCallModel

        /// The answer text of a call that ends in the answer of the caller.
        static let answerText = "The answer, after the tool calls."

        /// The answer text of the call that the delivered result starts.
        static let deliveryAnswerText = "The answer, after the result of the job."

        /// The id of the call of the job tool.
        static let jobCallId = "start-job-call"

        /// The start of the id of each `runCode` call; the index of the call
        /// in its round ends the id.
        static let runCodeCallIdPrefix = "run-code-call-"

        /// The arguments of the call of the job tool.
        static let jobArguments = #"{"value": "the job"}"#

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log and the script.
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
            model: NoOpToolCallModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(render: request.transcript)
            try Task.checkCancellation()
            switch nextStep(after: request.transcript) {
            case .answer(let text):
                await channel.send(.response(action: .appendText(text, tokenCount: Self.emittedTokenCount)))
            case .calls(let calls):
                for call in calls {
                    await channel.send(
                        .toolCalls(
                            action: .toolCall(
                                id: call.id, name: call.name,
                                action: .appendArguments(call.arguments, tokenCount: Self.emittedTokenCount))))
                }
            }
        }

        /// One tool call that a call of the script streams.
        private struct ScriptedCall {
            /// The id of the call.
            let id: String

            /// The name of the called tool.
            let name: String

            /// The JSON arguments of the call.
            let arguments: String
        }

        /// What one call of the script does.
        private enum Step {
            /// The call answers with this text.
            case answer(String)

            /// The call streams these tool calls, in order, as one round.
            case calls([ScriptedCall])
        }

        /// The step of the call over `transcript`, in the order of the type
        /// documentation of ``NoOpToolCallModel``.
        ///
        /// - Parameter transcript: The transcript of the call.
        /// - Returns: The step.
        private func nextStep(after transcript: Transcript) -> Step {
            if transcript.promptTexts.last?.contains(RoutedSessionActor.settledRunDeliveryPrompt) == true {
                return .answer(Self.deliveryAnswerText)
            }
            if configuration.startsJob, !Self.holdsOutput(of: NoOpToolCallModel.jobToolName, in: transcript) {
                return .calls([
                    ScriptedCall(id: Self.jobCallId, name: NoOpToolCallModel.jobToolName, arguments: Self.jobArguments)
                ])
            }
            if !Self.holdsOutput(of: CountingRunCodeTool.toolName, in: transcript) {
                return .calls(
                    configuration.codes.enumerated().map { index, code in
                        ScriptedCall(
                            id: Self.runCodeCallIdPrefix + "\(index)", name: CountingRunCodeTool.toolName,
                            arguments: Self.runCodeArguments(code: code))
                    })
            }
            return .answer(Self.answerText)
        }

        /// Whether `transcript` holds a tool output of the tool `toolName`.
        ///
        /// - Parameters:
        ///   - toolName: The name of the tool.
        ///   - transcript: The transcript to read.
        /// - Returns: `true` when an output of that tool is there.
        private static func holdsOutput(of toolName: String, in transcript: Transcript) -> Bool {
            transcript.contains { entry in
                guard case .toolOutput(let output) = entry else { return false }
                return output.toolName == toolName
            }
        }

        /// The JSON arguments of a `runCode` call with `code` as the snippet.
        ///
        /// - Parameter code: The snippet, with no quote and no backslash.
        /// - Returns: The JSON object text.
        static func runCodeArguments(code: String) -> String {
            #"{"code": ""# + code + #""}"#
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``NoOpToolCallModel``, with one ``CountingRunCodeTool`` and one
/// ``LatchedBackgroundToolRunner`` mounted, and a host check that marks a
/// `runCode` call as a no-op when its snippet is ``noOpCode`` (task
/// ^rw72f4j).
struct NoOpToolCallSessionFixture {
    /// The snippet that the host check of the fixture marks as a no-op.
    static let noOpCode = "return null"

    /// The output of the background job.
    static let jobOutput = "the job is done"

    /// The vended session a test drives its answers on.
    let session: RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The count of the runs of `runCode`.
    let runs: RunCount

    /// The latch that holds the background job until the test opens it.
    let gate: RunLatch

    /// The temp directory the router cached into, which ``end()`` removes.
    let directory: URL

    /// The host check of the fixture: a `runCode` call whose snippet is
    /// ``noOpCode`` is a no-op. Every other call is real.
    ///
    /// - Parameters:
    ///   - toolName: The name of the called tool.
    ///   - arguments: The arguments of the call.
    /// - Returns: `true` for a no-op call.
    static func isNoOp(toolName: String, arguments: GeneratedContent) -> Bool {
        let code = try? arguments.value(String.self, forProperty: "code")
        return toolName == CountingRunCodeTool.toolName && code == noOpCode
    }

    /// Builds a router and vends a session over a ``NoOpToolCallModel``.
    ///
    /// - Parameters:
    ///   - startsJob: Whether the model starts the background job first.
    ///   - codes: The snippets of the `runCode` calls of the model, all in
    ///     one round.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        startsJob: Bool, codes: [String], tempDirPrefix: String
    ) async throws -> NoOpToolCallSessionFixture {
        let log = RenderProbeLog()
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let runs = RunCount()
        let gate = RunLatch()
        let model = NoOpToolCallModel(log: log, startsJob: startsJob, codes: codes)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let job = LatchedBackgroundToolRunner(name: NoOpToolCallModel.jobToolName, gate: gate, output: jobOutput)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: [CountingRunCodeTool(runs: runs), job], isNoOpToolCall: isNoOp(toolName:arguments:)))
        return NoOpToolCallSessionFixture(session: session, log: log, runs: runs, gate: gate, directory: directory)
    }

    /// Ends the fixture: opens the gate, closes the session and removes the
    /// directory.
    func end() async {
        await gate.open()
        await session.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
