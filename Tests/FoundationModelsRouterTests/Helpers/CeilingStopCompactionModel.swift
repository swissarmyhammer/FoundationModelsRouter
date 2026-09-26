import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A deterministic `LanguageModel` for one answer whose first attempt stops at
/// its output token ceiling (task ^46bz58k).
///
/// Each executor call reads the transcript it is handed and does one of
/// three things:
///
/// - a compaction's summarizer call (its prompt holds the compaction prompt):
///   it answers with ``Executor/summaryText``;
/// - the continuation attempt after a compaction: it answers with
///   ``Executor/answerText``;
/// - any other call: it writes ``cutText`` and reports ``cutUsage`` as the
///   usage of the call, so the call spends its ceiling. When
///   ``cutEndsInsideReasoning`` is `true`, it writes ``cutText`` as a thought
///   and sends the `incompleteOutput` metadata instead of response text, as
///   the MLX executor does when the output ends inside a thought (task
///   ^gfxd7av).
struct CeilingStopCompactionModel: LanguageModel {
    /// The text of the call that stops at the ceiling.
    let cutText: String

    /// The usage the call that stops at the ceiling reports.
    let cutUsage: MeteredGenerationCall

    /// Whether the cut call ends inside its thought instead of inside its
    /// response text.
    let cutEndsInsideReasoning: Bool

    /// Declares reasoning, because a cut call can send a reasoning entry.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning]) }

    /// Builds the executor cache key from the scripted text and usage.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(cutText: cutText, cutUsage: cutUsage, cutEndsInsideReasoning: cutEndsInsideReasoning)
    }

    /// The executor that plays out the answer.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// The text of the call that stops at the ceiling.
            let cutText: String

            /// The usage the call that stops at the ceiling reports.
            let cutUsage: MeteredGenerationCall

            /// Whether the cut call ends inside its thought.
            let cutEndsInsideReasoning: Bool
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = CeilingStopCompactionModel

        /// The answer text of the continuation attempt.
        static let answerText = "The rest of the long answer."

        /// The summary text of a compaction's summarizer call.
        static let summaryText = "Summary: the assistant was writing a long answer."

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
            model: CeilingStopCompactionModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let prompts = request.transcript.promptTexts
            if prompts.contains(where: { $0.contains(CompactionPrompt.default.text) }) {
                await Self.send(text: Self.summaryText, entryID: "summary", usage: Self.smallCall, into: channel)
                return
            }
            if prompts.contains(where: { $0.contains(RoutedSessionActor.ceilingStopContinuationPrompt) }) {
                await Self.send(text: Self.answerText, entryID: "answer", usage: Self.smallCall, into: channel)
                return
            }
            if configuration.cutEndsInsideReasoning {
                await Self.sendCutInsideReasoning(configuration, into: channel)
                return
            }
            await Self.send(
                text: configuration.cutText, entryID: "cut", usage: configuration.cutUsage, into: channel)
        }

        /// Sends one text response and its usage.
        static func send(
            text: String, entryID: String, usage: MeteredGenerationCall,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(entryID: entryID, action: .appendText(text, tokenCount: emittedTokenCount)))
            await sendUsage(usage, entryID: entryID, into: channel)
        }

        /// Sends the cut text as a thought, then the `incompleteOutput`
        /// metadata and the usage on an empty response entry.
        ///
        /// - Parameters:
        ///   - configuration: The scripted cut text and usage.
        ///   - channel: The generation channel this call emits into.
        private static func sendCutInsideReasoning(
            _ configuration: Configuration, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .reasoning(
                    entryID: "cut-reasoning",
                    action: .appendText(configuration.cutText, tokenCount: emittedTokenCount)))
            await channel.send(.response(entryID: "cut", action: .updateMetadata(["incompleteOutput": true])))
            await sendUsage(configuration.cutUsage, entryID: "cut", into: channel)
        }

        /// Sends `usage` as the usage of the response entry `entryID`.
        private static func sendUsage(
            _ usage: MeteredGenerationCall, entryID: String,
            into channel: LanguageModelExecutorGenerationChannel
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
