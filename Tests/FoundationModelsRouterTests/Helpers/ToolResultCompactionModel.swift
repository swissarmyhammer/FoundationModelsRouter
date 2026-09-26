import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// A deterministic `LanguageModel` for one tool-using answer that a tool
/// result can stop for a compaction.
///
/// Each executor call reads the transcript it is handed and does one of
/// three things:
///
/// - a compaction's summarizer call (its prompt holds the compaction prompt):
///   it answers with ``Executor/summaryText``;
/// - a call after the tool ran, or the continuation attempt after a
///   compaction: it answers with ``Executor/answerText``;
/// - any other call: it reasons, asks for the ``LargeResultTool`` once, and
///   reports ``toolCallUsage`` as the usage of the call.
struct ToolResultCompactionModel: LanguageModel {
    /// The usage the call that asks for the tool reports.
    let toolCallUsage: MeteredGenerationCall

    /// Declares tool calling, because a tool-mounted session refuses a model
    /// without it.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the scripted usage.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(toolCallUsage: toolCallUsage)
    }

    /// The executor that plays out the answer.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// The usage the call that asks for the tool reports.
            let toolCallUsage: MeteredGenerationCall
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = ToolResultCompactionModel

        /// The answer text of the submission.
        static let answerText = "The large lookup result is in hand."

        /// The summary text of a compaction's summarizer call.
        static let summaryText = "Summary: the lookup tool returned one large result."

        /// The reasoning text of the call that asks for the tool.
        static let reasoningText = "I will call the lookup tool."

        /// The `value` argument of the one tool call.
        static let toolArgument = "lookup"

        /// The id of the one tool call.
        static let toolCallID = "large-call-0"

        /// The token count every emitted fragment reports. The usage of a call
        /// comes from its `.updateUsage` action, not from this count.
        private static let emittedTokenCount = 1

        /// The usage the answer and summary calls report.
        private static let smallCall = MeteredGenerationCall(tokensIn: 1, tokensOut: 1)

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The scripted usage.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Whether `transcript` holds a `.toolCalls` entry.
        private static func holdsToolCall(in transcript: Transcript) -> Bool {
            transcript.contains { entry in
                guard case .toolCalls = entry else { return false }
                return true
            }
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
            model: ToolResultCompactionModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let prompts = request.transcript.promptTexts
            if prompts.contains(where: { $0.contains(CompactionPrompt.default.text) }) {
                await Self.send(text: Self.summaryText, entryID: "summary", usage: Self.smallCall, into: channel)
                return
            }
            let continues = prompts.contains { $0.contains(RoutedSessionActor.compactionContinuationPrompt) }
            if continues || Self.holdsToolCall(in: request.transcript) {
                await Self.send(text: Self.answerText, entryID: "answer", usage: Self.smallCall, into: channel)
                return
            }
            await sendToolCall(into: channel)
        }

        /// Sends one text response and its usage.
        private static func send(
            text: String, entryID: String, usage: MeteredGenerationCall,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(entryID: entryID, action: .appendText(text, tokenCount: emittedTokenCount)))
            await send(usage: usage, entryID: entryID, into: channel)
        }

        /// Sends the reasoning, the one tool call, and the scripted usage.
        private func sendToolCall(into channel: LanguageModelExecutorGenerationChannel) async {
            await channel.send(
                .reasoning(
                    entryID: "reasoning",
                    action: .appendText(Self.reasoningText, tokenCount: Self.emittedTokenCount)))
            await channel.send(
                .toolCalls(
                    entryID: "tool-calls",
                    action: .toolCall(
                        id: Self.toolCallID,
                        name: LargeResultTool.toolName,
                        action: .appendArguments(
                            #"{"value":"\#(Self.toolArgument)"}"#, tokenCount: Self.emittedTokenCount))))
            await Self.send(usage: configuration.toolCallUsage, entryID: "tool-call-usage", into: channel)
        }

        /// Sends the usage of one call.
        private static func send(
            usage: MeteredGenerationCall, entryID: String, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(
                    entryID: entryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: usage.tokensIn, cachedTokenCount: 0),
                        output: .init(totalTokenCount: usage.tokensOut, reasoningTokenCount: 0))))
        }
    }
}

/// A tool that returns one large text result, so the result alone crosses a
/// session's compaction trigger.
///
/// With ``stopsSubmission`` set, the tool asks its session to stop the submission
/// before it returns, so a test can prove that a user stop stays a stop.
final class LargeResultTool: Tool, Sendable {
    /// The name the model calls the tool by.
    static let toolName = "lookup_large"

    let name = LargeResultTool.toolName
    let description = "test-only tool that returns one large text result"

    /// The text every call returns.
    let result: String

    /// The session a stopping call stops, set after the session exists.
    private let sessionToStop = Mutex<(any RoutedSession)?>(nil)

    /// How many times the model called the tool.
    private let callCount = Mutex(0)

    /// Makes the tool.
    ///
    /// - Parameter result: The text every call returns.
    init(result: String) {
        self.result = result
    }

    /// Makes every later call stop the submission of `session` before it returns.
    ///
    /// - Parameter session: The session whose submission the call stops.
    func stopsSubmission(of session: any RoutedSession) {
        sessionToStop.withLock { $0 = session }
    }

    /// How many times the model called the tool.
    var calls: Int {
        callCount.withLock { $0 }
    }

    func call(arguments: AmbientToolArguments) async throws -> String {
        callCount.withLock { $0 += 1 }
        if let session = sessionToStop.withLock({ $0 }) {
            _ = await session.cancel()
        }
        return result
    }
}
