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

    /// The id of the first entry of the transcript that the pass received,
    /// or `nil` for an empty transcript. The fork keys a pass with no scope
    /// by this id.
    let firstEntryID: String?
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

    /// The keys that the passes so far put in the prompt cache, as the fork
    /// keys a pass: the id of a `.session` scope, or the id of the first
    /// transcript entry when no scope is bound. A pass with the `.uncached`
    /// scope puts no key.
    var storeKeys: Set<String> {
        Set(
            recordedPasses.compactMap { pass in
                switch pass.scope {
                case .session(let sessionID)?: sessionID
                case .uncached?: nil
                case nil: pass.firstEntryID
                }
            })
    }

    /// The scopes of the passes whose prompt is none of `prompts`, in order:
    /// the passes that no caller prompt started, such as a summarizer call.
    ///
    /// - Parameter prompts: The caller prompts of the session.
    /// - Returns: The scope of each other pass.
    func scopes(notServingPrompts prompts: Set<String>) -> [MLXLanguageModel.PromptCacheScope?] {
        recordedPasses.filter { !prompts.contains($0.prompt) }.map(\.scope)
    }
}

/// A scripted `LanguageModel` that records the prompt-cache scope of each pass
/// and each release of the cache of a session, with no GPU.
///
/// Each pass records the `MLXLanguageModel.promptCacheScope` that its task
/// sees, and then answers ``answer``. The model takes the place of the raw
/// `MLXLanguageModel` of a container: it releases the cache of a session
/// through the same ``SessionPromptCacheReleasing`` requirement.
///
/// A model made with a ``reportedInputTokens`` above zero also reports that
/// input count as the usage of each pass, so the session measures its
/// context and its automatic compaction can start.
struct PromptCacheScopeRecordingModel: LanguageModel, SessionPromptCacheReleasing {
    /// The log each pass and each release records into.
    let log: PromptCacheScopeLog

    /// The input token count that each pass reports as its usage, or zero
    /// when the passes report no usage.
    let reportedInputTokens: Int

    /// The text of every answer. It is short, so a summary that it writes
    /// shrinks the live context of a compaction.
    static let answer = "ok"

    /// Makes a model over `log`.
    ///
    /// - Parameters:
    ///   - log: The log each pass and each release records into.
    ///   - reportedInputTokens: The input token count that each pass reports
    ///     as its usage. The default, zero, reports no usage.
    init(log: PromptCacheScopeLog, reportedInputTokens: Int = 0) {
        self.log = log
        self.reportedInputTokens = reportedInputTokens
    }

    /// The model answers text only.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor cache key: the identity of the log, with the usage that
    /// each pass reports.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, reportedInputTokens: reportedInputTokens)
    }

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

            /// The input token count that each pass reports, or zero for no
            /// usage report.
            let reportedInputTokens: Int

            /// Equal when both configurations name the same log and report
            /// the same usage.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log object and the
            ///   same reported input count.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.reportedInputTokens == rhs.reportedInputTokens
            }

            /// Hashes by the `ObjectIdentifier` of the log and by the
            /// reported input count.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(reportedInputTokens)
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

        /// Records the scope that the task of this pass sees, answers, and
        /// reports the configured usage.
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
                ScopedPass(
                    scope: MLXLanguageModel.promptCacheScope, prompt: Self.lastPrompt(of: request.transcript),
                    firstEntryID: Array(request.transcript).first?.id))
            await channel.send(
                .response(
                    action: .appendText(PromptCacheScopeRecordingModel.answer, tokenCount: Self.emittedTokenCount)))
            await reportUsage(into: channel)
        }

        /// Reports ``Configuration/reportedInputTokens`` as the usage of the
        /// pass, when it is above zero.
        ///
        /// - Parameter channel: The channel the pass emits into.
        private func reportUsage(into channel: LanguageModelExecutorGenerationChannel) async {
            guard configuration.reportedInputTokens > 0 else { return }
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(totalTokenCount: configuration.reportedInputTokens, cachedTokenCount: 0),
                        output: .init(totalTokenCount: Self.emittedTokenCount, reasoningTokenCount: 0))))
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
