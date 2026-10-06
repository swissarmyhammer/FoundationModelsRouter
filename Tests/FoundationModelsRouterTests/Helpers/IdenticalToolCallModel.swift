import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// The tool calls that an ``IdenticalToolCallModel`` makes (task ^8eq31j0).
struct IdenticalToolCallScript: Sendable, Hashable {
    /// The code of each `runCode` call of the first submission, in order. The
    /// model makes one call for each generation pass.
    let codes: [String]

    /// The code of the one `runCode` call of the final pass, or `nil` when
    /// the final pass gives only text.
    let finalPassCode: String?
}

/// A deterministic `LanguageModel` that makes a script of short `runCode`
/// tool calls, one call for each generation pass (task ^8eq31j0).
///
/// Each executor call records the transcript it receives in ``log``, then:
///
/// - in the first submission (one prompt in the transcript), the pass makes
///   the call of ``IdenticalToolCallScript/codes`` whose index is the count of
///   the tool outputs so far, and answers with ``Executor/answerText`` when
///   the script has no call left;
/// - in the final pass (the last prompt ends with
///   ``RoutedSessionActor/finalPassPrompt``), the first pass makes the call
///   of ``IdenticalToolCallScript/finalPassCode``, and the pass after its tool
///   output answers with ``Executor/answerText``;
/// - each other pass, a recovery for example, answers with
///   ``Executor/answerText``.
///
/// The arguments of each call are the JSON object `{"code": "<code>"}`. A
/// code has no line feed, so the line window of the watch never fills.
struct IdenticalToolCallModel: LanguageModel {
    /// The log that records the transcript of each call.
    let log: RenderProbeLog

    /// The tool calls the model makes.
    let script: IdenticalToolCallScript

    /// Declares tool calling, which a session with tools needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the log and the script.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, script: script)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records the transcript of each call.
            let log: RenderProbeLog

            /// The tool calls the model makes.
            let script: IdenticalToolCallScript

            /// Identity equality on the log, value equality on the script.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log and script.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.script == rhs.script
            }

            /// Hashes the identity of the log and the script.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(script)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = IdenticalToolCallModel

        /// The answer text of a pass that makes no tool call.
        static let answerText = "The answer, after the tool calls."

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The count of prompts in the transcript of the first submission.
        private static let firstSubmissionPromptCount = 1

        /// The id of the one tool call of the final pass.
        private static let finalPassCallId = "final-pass-call"

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
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: IdenticalToolCallModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(render: request.transcript)
            guard let call = Self.nextCall(in: request.transcript, script: configuration.script) else {
                await channel.send(.response(action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
                return
            }
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: call.id, name: CountingRunCodeTool.toolName,
                        action: .appendArguments(Self.argumentsJSON(code: call.code), tokenCount: Self.emittedTokenCount)))
            )
        }

        /// The tool call that a pass over `transcript` makes, or `nil` when
        /// the pass answers with text.
        ///
        /// - Parameters:
        ///   - transcript: The transcript of the pass.
        ///   - script: The tool calls the model makes.
        /// - Returns: The id and the code of the call, or `nil`.
        private static func nextCall(
            in transcript: Transcript, script: IdenticalToolCallScript
        ) -> (id: String, code: String)? {
            let prompts = transcript.promptTexts
            let outputs = toolOutputCountAfterLastPrompt(in: transcript)
            if prompts.count == firstSubmissionPromptCount {
                return outputs < script.codes.count ? ("call-\(outputs)", script.codes[outputs]) : nil
            }
            let isFinalPass = prompts.last?.hasSuffix(RoutedSessionActor.finalPassPrompt) == true
            guard isFinalPass, outputs == 0, let code = script.finalPassCode else { return nil }
            return (finalPassCallId, code)
        }

        /// The count of the `.toolOutput` entries of `transcript` after its
        /// last `.prompt` entry.
        ///
        /// - Parameter transcript: The transcript of the pass.
        /// - Returns: The count.
        private static func toolOutputCountAfterLastPrompt(in transcript: Transcript) -> Int {
            transcript.reduce(into: 0) { count, entry in
                switch entry {
                case .prompt:
                    count = 0
                case .toolOutput:
                    count += 1
                default:
                    break
                }
            }
        }

        /// The arguments of one `runCode` call with `code`.
        ///
        /// - Parameter code: The code of the call. It holds no quote, no
        ///   backslash and no line feed.
        /// - Returns: The JSON object of the arguments.
        private static func argumentsJSON(code: String) -> String {
            #"{"code": "\#(code)"}"#
        }
    }
}
