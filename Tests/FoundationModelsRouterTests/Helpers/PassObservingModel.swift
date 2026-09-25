import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// One executor pass that a ``PassObservingModel`` served.
struct ObservedPass: Sendable, Equatable {
    /// The identity of the executor instance that ran the pass.
    let executor: ObjectIdentifier

    /// The text of the last prompt of the transcript that the pass received.
    let prompt: String
}

/// The passes that the executors of one ``PassObservingModel`` served, in the
/// order they started.
///
/// A `Mutex`, not an actor: an executor records its pass before its first
/// suspension, so the order of the log is the order the passes started.
final class ObservedPassLog: Sendable {
    /// The passes so far, in the order they started.
    private let passes = Mutex<[ObservedPass]>([])

    /// Records one pass.
    ///
    /// - Parameter pass: The pass that started.
    func record(_ pass: ObservedPass) {
        passes.withLock { $0.append(pass) }
    }

    /// Every pass so far, in the order it started.
    var recorded: [ObservedPass] { passes.withLock { $0 } }

    /// The executors that ran the passes whose prompt is `prompt`.
    ///
    /// - Parameter prompt: The prompt of the passes to read.
    /// - Returns: The executor identity of each such pass, without repeats.
    func executors(servingPrompt prompt: String) -> Set<ObjectIdentifier> {
        Set(recorded.filter { $0.prompt == prompt }.map(\.executor))
    }
}

/// A scripted `LanguageModel` that makes each executor call an observable pass.
///
/// Each pass records which executor instance ran it and which prompt it got,
/// reports its entry and its exit to a ``ConcurrencyPeakObserver``, and stays
/// inside the call until a ``RunLatch`` opens. Then it answers with
/// ``answer(to:)``. A test thus sees whether two passes overlapped, and which
/// executor ran each pass, with no GPU and no clock.
struct PassObservingModel: LanguageModel {
    /// The observer each pass reports its entry and its exit to.
    let observer: ConcurrencyPeakObserver

    /// The latch each pass waits on before it answers.
    let latch: RunLatch

    /// The log each pass records into.
    let passes: ObservedPassLog

    /// The text an answer opens with.
    static let answerPrefix = "answered: "

    /// The answer a pass gives to a prompt.
    ///
    /// - Parameter prompt: The prompt of the pass.
    /// - Returns: The answer text.
    static func answer(to prompt: String) -> String {
        answerPrefix + prompt
    }

    /// The model declares no capability. A pass only answers text.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

    /// The executor cache key: the identities of the observer, the latch, and
    /// the log.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(observer: observer, latch: latch, passes: passes)
    }

    /// The executor that serves one observable pass for each call.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares by the identities of the
        /// reference-typed parts, which have no value equality of their own.
        struct Configuration: Sendable, Hashable {
            /// The observer each pass reports to.
            let observer: ConcurrencyPeakObserver

            /// The latch each pass waits on.
            let latch: RunLatch

            /// The log each pass records into.
            let passes: ObservedPassLog

            /// Equal when all three parts are the same objects.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when the parts are the same objects.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.observer === rhs.observer && lhs.latch === rhs.latch && lhs.passes === rhs.passes
            }

            /// Hashes the identities that ``==(_:_:)`` compares.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(observer))
                hasher.combine(ObjectIdentifier(latch))
                hasher.combine(ObjectIdentifier(passes))
            }
        }

        /// The model type this executor serves.
        typealias Model = PassObservingModel

        /// A marker object that gives this executor instance its own identity.
        private final class Identity: Sendable {}

        /// The token count each emitted fragment reports. The model meters
        /// nothing.
        private static let emittedTokenCount = 1

        /// The configuration the SDK built this executor with.
        private let configuration: Configuration

        /// The identity of this executor instance.
        private let identity = Identity()

        /// Stores `configuration`.
        ///
        /// - Parameter configuration: The observer, the latch, and the log.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the pass, holds it until the latch opens, and answers the
        /// last prompt of the transcript.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: The model. Unread: the parts arrive through the
        ///     configuration.
        ///   - channel: The channel the answer is sent into.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PassObservingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let prompt = Self.lastPromptText(in: request.transcript)
            configuration.passes.record(ObservedPass(executor: ObjectIdentifier(identity), prompt: prompt))
            await configuration.observer.enter()
            await configuration.latch.waitUntilOpen()
            await configuration.observer.exit()
            await channel.send(
                .response(
                    action: .appendText(PassObservingModel.answer(to: prompt), tokenCount: Self.emittedTokenCount)))
        }

        /// The text of the last `.prompt` entry of `transcript`.
        ///
        /// - Parameter transcript: The transcript of the pass.
        /// - Returns: The joined text segments of that entry, or the empty
        ///   string when the transcript holds no prompt.
        private static func lastPromptText(in transcript: Transcript) -> String {
            let prompts = transcript.compactMap { entry -> Transcript.Prompt? in
                guard case .prompt(let prompt) = entry else { return nil }
                return prompt
            }
            return WatchedText.text(of: prompts.last?.segments ?? [])
        }
    }
}
