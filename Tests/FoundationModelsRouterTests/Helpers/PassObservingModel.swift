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
/// inside the call until a ``RunLatch`` opens. When ``step`` is set, the pass
/// then also waits for one signal of that semaphore, so a test releases the
/// passes one at a time and sees which pass the queue admits next. A test thus
/// sees whether two passes overlapped, and which executor ran each pass, with
/// no GPU and no clock.
///
/// A session that mounts a tool gets ``toolRounds`` passes that each call the
/// first mounted tool, and then one pass that answers with ``answer(to:)``. A
/// session that mounts no tool gets one pass that answers.
struct PassObservingModel: LanguageModel {
    /// The observer each pass reports its entry and its exit to.
    let observer: ConcurrencyPeakObserver

    /// The latch each pass waits on before it answers.
    let latch: RunLatch

    /// The log each pass records into.
    let passes: ObservedPassLog

    /// The semaphore each pass waits on after the latch, or `nil` for passes
    /// that go on when the latch opens.
    let step: AsyncSemaphore?

    /// How many passes of one turn call a tool, in a session that mounts one.
    let toolRounds: Int

    /// The text an answer opens with.
    static let answerPrefix = "answered: "

    /// Stores the parts every pass uses.
    ///
    /// - Parameters:
    ///   - observer: The observer each pass reports to.
    ///   - latch: The latch each pass waits on.
    ///   - passes: The log each pass records into.
    ///   - step: The semaphore each pass waits on after the latch, or `nil`
    ///     (the default) for no step.
    ///   - toolRounds: How many passes of one turn call a tool. The default
    ///     is none, so each turn is one pass that answers.
    init(
        observer: ConcurrencyPeakObserver, latch: RunLatch, passes: ObservedPassLog,
        step: AsyncSemaphore? = nil, toolRounds: Int = 0
    ) {
        self.observer = observer
        self.latch = latch
        self.passes = passes
        self.step = step
        self.toolRounds = toolRounds
    }

    /// The answer the last pass of a turn gives to a prompt.
    ///
    /// - Parameter prompt: The prompt of the turn.
    /// - Returns: The answer text.
    static func answer(to prompt: String) -> String {
        answerPrefix + prompt
    }

    /// Declares tool calling only for a model that plays a tool loop, which a
    /// tool-mounted session requires. A model with no tool rounds only answers
    /// text.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(toolRounds > 0 ? [.toolCalling] : [])
    }

    /// The executor cache key: the identities of the parts and the loop
    /// length.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            observer: observer, latch: latch, passes: passes, step: step, toolRounds: toolRounds)
    }

    /// The executor that serves one observable pass for each call.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares the reference-typed parts
        /// by identity, because they have no value equality of their own.
        struct Configuration: Sendable, Hashable {
            /// The observer each pass reports to.
            let observer: ConcurrencyPeakObserver

            /// The latch each pass waits on.
            let latch: RunLatch

            /// The log each pass records into.
            let passes: ObservedPassLog

            /// The semaphore each pass waits on after the latch, or `nil`.
            let step: AsyncSemaphore?

            /// How many passes of one turn call a tool.
            let toolRounds: Int

            /// Equal when the loop lengths are equal and the parts are the
            /// same objects.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both configurations name the same parts
            ///   and the same loop.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.observer === rhs.observer && lhs.latch === rhs.latch && lhs.passes === rhs.passes
                    && lhs.step === rhs.step && lhs.toolRounds == rhs.toolRounds
            }

            /// Hashes what ``==(_:_:)`` compares.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(observer))
                hasher.combine(ObjectIdentifier(latch))
                hasher.combine(ObjectIdentifier(passes))
                hasher.combine(step.map(ObjectIdentifier.init))
                hasher.combine(toolRounds)
            }
        }

        /// The model type this executor serves.
        typealias Model = PassObservingModel

        /// The prompt of the turn a transcript ends in, and how many tool
        /// rounds that turn has played so far.
        private struct Turn {
            /// The joined text of the last `.prompt` entry, or the empty
            /// string when the transcript holds no prompt.
            let prompt: String

            /// The count of `.toolCalls` entries after that prompt.
            let toolRounds: Int
        }

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
        /// - Parameter configuration: The parts and the loop length.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the pass, holds it until the latch opens and its step
        /// arrives, and then calls the first mounted tool or answers the
        /// prompt of the turn.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: The model. Unread: the parts arrive through the
        ///     configuration.
        ///   - channel: The channel the pass emits into.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PassObservingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let turn = Self.currentTurn(of: request.transcript)
            configuration.passes.record(ObservedPass(executor: ObjectIdentifier(identity), prompt: turn.prompt))
            await configuration.observer.enter()
            await configuration.latch.waitUntilOpen()
            await configuration.step?.wait()
            await configuration.observer.exit()
            guard let tool = request.enabledToolDefinitions.first, turn.toolRounds < configuration.toolRounds
            else {
                await channel.send(
                    .response(
                        action: .appendText(
                            PassObservingModel.answer(to: turn.prompt), tokenCount: Self.emittedTokenCount)))
                return
            }
            await Self.callTool(named: tool.name, in: turn, into: channel)
        }

        /// Emits one call of the tool `name`, whose one argument names the
        /// round of `turn`.
        ///
        /// The argument is JSON-encoded, so a prompt with quotes or line
        /// breaks (a delivery prompt with a pending-run envelope) gives valid
        /// arguments.
        ///
        /// - Parameters:
        ///   - name: The name of the tool to call.
        ///   - turn: The turn the call belongs to.
        ///   - channel: The channel the call is sent into.
        private static func callTool(
            named name: String, in turn: Turn, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            let round = "\(turn.prompt)-\(turn.toolRounds)"
            await channel.send(
                .toolCalls(
                    entryID: round,
                    action: .toolCall(
                        id: round,
                        name: name,
                        action: .appendArguments(
                            GeneratedContent(properties: ["value": round]).jsonString,
                            tokenCount: emittedTokenCount))))
        }

        /// The turn `transcript` ends in.
        ///
        /// - Parameter transcript: The transcript of the pass.
        /// - Returns: The text of the last `.prompt` entry, and the count of
        ///   `.toolCalls` entries after it.
        private static func currentTurn(of transcript: Transcript) -> Turn {
            let entries = Array(transcript)
            let lastPromptIndex = entries.lastIndex { entry in
                guard case .prompt = entry else { return false }
                return true
            }
            guard let lastPromptIndex, case .prompt(let prompt) = entries[lastPromptIndex] else {
                return Turn(prompt: "", toolRounds: 0)
            }
            let roundsSincePrompt = entries[lastPromptIndex...].filter { entry in
                guard case .toolCalls = entry else { return false }
                return true
            }
            return Turn(prompt: WatchedText.text(of: prompt.segments), toolRounds: roundsSincePrompt.count)
        }
    }
}
