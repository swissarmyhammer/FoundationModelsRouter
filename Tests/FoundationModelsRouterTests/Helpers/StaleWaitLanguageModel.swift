import FoundationModels
import FoundationModelsExtras

/// A deterministic `LanguageModel` whose first ``waitingCalls`` generation
/// calls answer with only a waiting status, as Recursive Flint did after the
/// result of its wait was already in the context, and whose later calls
/// answer with ``Executor/answerText``.
///
/// Each call records the transcript it was handed in a ``RejectingModelLog``,
/// so a test can read what the model saw on each call.
struct StaleWaitLanguageModel: FoundationModels.LanguageModel {
    /// The log each generation call writes its transcript into.
    let log: RejectingModelLog

    /// How many generation calls answer with the waiting status.
    var waitingCalls = 1

    /// Declares tool calling, the one capability a tool-calling model needs.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    /// Builds the executor cache key from the log.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, waitingCalls: waitingCalls)
    }

    /// The executor that answers with the waiting status, then with the answer.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// The log to write each transcript into.
            let log: RejectingModelLog

            /// How many generation calls answer with the waiting status.
            let waitingCalls: Int
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = StaleWaitLanguageModel

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The waiting status of the first call. It names work that is not
        /// pending.
        static let waitingText =
            "\(PendingRunEnvelope.waitingStatusPrefix) the review double-check agent. "
            + "Its completion token is `01M7E507Q7TJ09AEP24YS5T1TH`."

        /// The answer of each later call.
        static let answerText = "The review passed. I commit the change now."

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the transcript, then answers with the waiting status on the
        /// first ``Configuration/waitingCalls`` calls and with the answer
        /// after them.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model _: StaleWaitLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = configuration.log.record(transcript: request.transcript)
            let text = callIndex < configuration.waitingCalls ? Self.waitingText : Self.answerText
            await channel.send(.response(action: .appendText(text, tokenCount: Self.emittedTokenCount)))
        }
    }
}
