import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// One tool call of a ``ScriptedRoundsModel`` round.
struct ScriptedRoundCall: Sendable, Hashable {
    /// The name of the called tool.
    let name: String

    /// The JSON arguments of the call.
    let arguments: String
}

/// A deterministic `LanguageModel` that plays a list of tool-call rounds,
/// then answers.
///
/// Each executor call records the transcript it receives in ``log``. The
/// count of the `.toolCalls` entries of that transcript is the index of the
/// round to play: a call streams the calls of that round, and a call past the
/// last round answers with ``Executor/answerText``. A stopped and recorded
/// round stays in the transcript, so the model goes on with the next round.
struct ScriptedRoundsModel: LanguageModel {
    /// The log that records the transcript of each call.
    let log: RenderProbeLog

    /// The rounds of tool calls, in order.
    let rounds: [[ScriptedRoundCall]]

    /// Declares tool calling, which a session with tools needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the log and the script.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, rounds: rounds)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records the transcript of each call.
            let log: RenderProbeLog

            /// The rounds of tool calls, in order.
            let rounds: [[ScriptedRoundCall]]

            /// Identity equality on the log, value equality on the script.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.rounds == rhs.rounds
            }

            /// Hashes the identity of the log and the script.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(rounds)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = ScriptedRoundsModel

        /// The answer text after the last round.
        static let answerText = "The answer, after the rounds."

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
            model: ScriptedRoundsModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(render: request.transcript)
            try Task.checkCancellation()
            let index = request.transcript.filter { entry in
                guard case .toolCalls = entry else { return false }
                return true
            }.count
            guard index < configuration.rounds.count else {
                await channel.send(.response(action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
                return
            }
            for (position, call) in configuration.rounds[index].enumerated() {
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: "round-\(index)-call-\(position)", name: call.name,
                            action: .appendArguments(call.arguments, tokenCount: Self.emittedTokenCount))))
            }
        }
    }
}
