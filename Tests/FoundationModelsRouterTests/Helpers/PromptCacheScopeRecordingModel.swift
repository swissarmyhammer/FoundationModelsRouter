import FoundationModels
import MLXFoundationModels
import Synchronization

@testable import FoundationModelsRouter

/// One executor pass that a ``PromptCacheScopeRecordingModel`` served.
struct ScopedPass: Sendable, Equatable {
    /// The prompt-cache scope that the task of the pass saw, or `nil` when
    /// no scope was bound.
    let scope: MLXLanguageModel.PromptCacheScope?

    /// The text of the last prompt of the transcript that the pass received.
    let prompt: String
}

/// The passes and the cache releases of one ``PromptCacheScopeRecordingModel``,
/// in the order they occurred.
///
/// A `Mutex`, not an actor: an executor records its pass before its first
/// suspension, so the order of the log is the order the passes started.
final class PromptCacheScopeLog: Sendable {
    /// The passes so far, in the order they started.
    private let passes = Mutex<[ScopedPass]>([])

    /// The session ids whose cache the model released, in order.
    private let releases = Mutex<[String]>([])

    /// Records one pass.
    ///
    /// - Parameter pass: The pass that started.
    func record(_ pass: ScopedPass) {
        passes.withLock { $0.append(pass) }
    }

    /// Records one release of the cache of a session.
    ///
    /// - Parameter sessionID: The session id whose cache was released.
    func recordRelease(of sessionID: String) {
        releases.withLock { $0.append(sessionID) }
    }

    /// Every pass so far, in the order it started.
    var recordedPasses: [ScopedPass] { passes.withLock { $0 } }

    /// Every released session id so far, in order.
    var releasedSessionIDs: [String] { releases.withLock { $0 } }

    /// The scopes of the passes whose prompt is `prompt`, in order.
    ///
    /// - Parameter prompt: The prompt of the passes to read.
    /// - Returns: The scope of each such pass.
    func scopes(servingPrompt prompt: String) -> [MLXLanguageModel.PromptCacheScope?] {
        recordedPasses.filter { $0.prompt == prompt }.map(\.scope)
    }

    /// The session ids of every `.session` scope that a pass saw, without
    /// repeats: the keys the passes put in the prompt cache.
    var sessionKeys: Set<String> {
        Set(
            recordedPasses.compactMap { pass in
                guard case .session(let sessionID)? = pass.scope else { return nil }
                return sessionID
            })
    }
}

/// A scripted `LanguageModel` that records the prompt-cache scope of each pass
/// and each release of the cache of a session, with no GPU.
///
/// Each pass records the `MLXLanguageModel.promptCacheScope` that its task
/// sees, and then answers ``answer``. The model takes the place of the raw
/// `MLXLanguageModel` of a container: it releases the cache of a session
/// through the same ``SessionPromptCacheReleasing`` requirement.
struct PromptCacheScopeRecordingModel: LanguageModel, SessionPromptCacheReleasing {
    /// The log each pass and each release records into.
    let log: PromptCacheScopeLog

    /// The text of every answer. It is short, so a summary that it writes
    /// shrinks the live context of a compaction.
    static let answer = "ok"

    /// The model answers text only.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor cache key: the identity of the log.
    var executorConfiguration: Executor.Configuration { Executor.Configuration(log: log) }

    /// Records the release of the cache of `sessionID`.
    ///
    /// - Parameter sessionID: The session id whose cache is released.
    func releasePromptCache(sessionID: String) async {
        log.recordRelease(of: sessionID)
    }

    /// The executor that records the scope of each pass and answers.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares the log by identity.
        struct Configuration: Sendable, Hashable {
            /// The log each pass records into.
            let log: PromptCacheScopeLog

            /// Equal when both configurations name the same log.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log object.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log
            }

            /// Hashes by the `ObjectIdentifier` of the log.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
            }
        }

        /// The model type this executor serves.
        typealias Model = PromptCacheScopeRecordingModel

        /// The token count the one emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The configuration the SDK built this executor with.
        private let configuration: Configuration

        /// Stores `configuration`.
        ///
        /// - Parameter configuration: The log.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the scope that the task of this pass sees, and answers.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: The model. Unread: the log arrives through the
        ///     configuration.
        ///   - channel: The channel the pass emits into.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PromptCacheScopeRecordingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(
                ScopedPass(scope: MLXLanguageModel.promptCacheScope, prompt: Self.lastPrompt(of: request.transcript)))
            await channel.send(
                .response(
                    action: .appendText(PromptCacheScopeRecordingModel.answer, tokenCount: Self.emittedTokenCount)))
        }

        /// The text of the last `.prompt` entry of `transcript`.
        ///
        /// - Parameter transcript: The transcript of the pass.
        /// - Returns: The joined text of the last prompt, or the empty string
        ///   when the transcript holds no prompt.
        private static func lastPrompt(of transcript: Transcript) -> String {
            let lastPrompt = Array(transcript).reversed().lazy.compactMap { entry -> Transcript.Prompt? in
                guard case .prompt(let prompt) = entry else { return nil }
                return prompt
            }.first
            return lastPrompt.map { WatchedText.text(of: $0.segments) } ?? ""
        }
    }
}
