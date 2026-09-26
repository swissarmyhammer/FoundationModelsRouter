import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// What one model call of an ``AnswerLimitsModel`` does (task ^5d0qx1b).
enum AnswerLimitsStep: Sendable, Equatable {
    /// Writes ``AnswerLimitsModel/longCutText`` and reports
    /// ``AnswerLimitsModel/ceilingStopUsage``: the call spends its ceiling
    /// with the context over the trigger, and the counted transcript is over
    /// the target, so the compaction applies a summary.
    case ceilingStopThatCompacts

    /// Writes ``AnswerLimitsModel/shortCutText`` and reports
    /// ``AnswerLimitsModel/ceilingStopUsage``: the call spends its ceiling
    /// with the context over the trigger, but the counted transcript is under
    /// the target, so the compaction applies no summary.
    case ceilingStopWithNothingToCompact

    /// Writes reasoning that repeats itself, and waits until the repetition
    /// watch of the session stops the call.
    case repeating

    /// Writes ``AnswerLimitsModel/answerText``.
    case answer
}

/// The steps that an ``AnswerLimitsModel`` plays, in order: one step for each
/// model call that is not the summarizer call of a compaction.
///
/// A test adds the steps of each answer before it sends the message of that
/// answer, and reads what is left after the answer. A call that finds no step
/// answers with ``AnswerLimitsModel/unscriptedText`` and is counted.
final class AnswerLimitsScript: Sendable {
    /// The steps that wait, and the count of calls that found none.
    private struct State {
        /// The steps that wait, in order.
        var steps: [AnswerLimitsStep] = []

        /// The calls that found no step.
        var unscriptedCalls = 0
    }

    /// The state, which the executor changes on the tasks of the SDK.
    private let state = Mutex(State())

    /// Adds `steps` after the steps that wait.
    ///
    /// - Parameter steps: The steps of the next answer.
    func add(_ steps: [AnswerLimitsStep]) {
        state.withLock { $0.steps += steps }
    }

    /// Takes the next step, or counts a call that found none.
    ///
    /// - Returns: The next step, or `nil` when no step waits.
    func takeNextStep() -> AnswerLimitsStep? {
        state.withLock { state in
            guard !state.steps.isEmpty else {
                state.unscriptedCalls += 1
                return nil
            }
            return state.steps.removeFirst()
        }
    }

    /// The steps that still wait.
    var remainingSteps: [AnswerLimitsStep] {
        state.withLock(\.steps)
    }

    /// The calls that found no step.
    var unscriptedCalls: Int {
        state.withLock(\.unscriptedCalls)
    }
}

/// A deterministic `LanguageModel` whose calls play the steps of an
/// ``AnswerLimitsScript`` (task ^5d0qx1b). It drives the limits of an answer:
/// the stop of the compactions inside an answer, and the count of the
/// repetition recoveries.
///
/// A summarizer call of a compaction (its prompt holds the compaction
/// prompt) answers with ``Executor/summaryText`` and takes no step. Each
/// other call takes the next step of the script.
struct AnswerLimitsModel: LanguageModel {
    /// The output token ceiling that the caller of each answer names.
    static let ceiling = 500

    /// The input tokens of a call that stops at ``ceiling``.
    private static let ceilingStopTokensIn = 400

    /// The usage of a call that stops at ``ceiling``: ``ceilingStopTokensIn``
    /// input tokens and the whole ceiling, so the context of 900 tokens is over
    /// the trigger of ``AnswerLimitsSessionFixture/budget`` (800 tokens).
    static let ceilingStopUsage = MeteredGenerationCall(tokensIn: ceilingStopTokensIn, tokensOut: ceiling)

    /// The usage of an answer call and of a summarizer call.
    static let smallUsage = MeteredGenerationCall(tokensIn: 1, tokensOut: 1)

    /// The length of ``longCutText``, in characters (one token each): more
    /// than the target of 500 tokens, so a compaction has content to summarize.
    private static let longCutLength = 900

    /// The length of ``shortCutText``, in characters.
    private static let shortCutLength = 20

    /// The text of a ``AnswerLimitsStep/ceilingStopThatCompacts`` call.
    static let longCutText = "CUT:" + String(repeating: "x", count: longCutLength)

    /// The text of a ``AnswerLimitsStep/ceilingStopWithNothingToCompact`` call.
    static let shortCutText = "CUT:" + String(repeating: "y", count: shortCutLength)

    /// The text of an ``AnswerLimitsStep/answer`` call.
    static let answerText = "The answer, with the limits in force."

    /// The text of a call that found no step.
    static let unscriptedText = "No step was left for this call."

    /// The lines a ``AnswerLimitsStep/repeating`` call writes one time,
    /// before it repeats.
    private static let newLines = [
        "First I read the failing test and its fixture.",
        "The fixture builds the query with a stale alias.",
    ]

    /// The lines a ``AnswerLimitsStep/repeating`` call writes again and again.
    private static let cycle = [
        "Maybe the alias is resolved in the compiler.",
        "Let me look at how the compiler resolves it.",
        "So the compiler keeps the alias from the join.",
    ]

    /// How many times a ``AnswerLimitsStep/repeating`` call writes ``cycle``:
    /// far more than one window of the detection of the tests.
    private static let cycleCount = 40

    /// The hold of a ``AnswerLimitsStep/repeating`` call, in seconds.
    private static let repeatingHoldSeconds = 5

    /// The hold of a ``AnswerLimitsStep/repeating`` call. It ends only when
    /// the session stops the call, or the test fails on what follows.
    private static let repeatingHold = Duration.seconds(repeatingHoldSeconds)

    /// The reasoning of a ``AnswerLimitsStep/repeating`` call.
    static let repeatingScript = RepeatingReasoningScript.repeating(
        newLines: newLines, cycle: cycle, cycleCount: cycleCount, hold: repeatingHold)

    /// The script the calls play.
    let script: AnswerLimitsScript

    /// Declares reasoning, because a repeating call writes a reasoning entry.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning]) }

    /// Builds the executor cache key from the script.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(script: script)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The script
        /// is compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The script the calls play.
            let script: AnswerLimitsScript

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.script === rhs.script
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(script))
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = AnswerLimitsModel

        /// The summary text of a compaction's summarizer call.
        static let summaryText = "Summary: the assistant was writing a long answer."

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The script.
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
        /// - Throws: `CancellationError` when the session stops a repeating call.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: AnswerLimitsModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let prompts = request.transcript.promptTexts
            if prompts.contains(where: { $0.contains(CompactionPrompt.default.text) }) {
                await Self.send(Self.summaryText, usage: AnswerLimitsModel.smallUsage, into: channel)
                return
            }
            switch configuration.script.takeNextStep() {
            case .ceilingStopThatCompacts:
                await Self.send(AnswerLimitsModel.longCutText, usage: AnswerLimitsModel.ceilingStopUsage, into: channel)
            case .ceilingStopWithNothingToCompact:
                await Self.send(AnswerLimitsModel.shortCutText, usage: AnswerLimitsModel.ceilingStopUsage, into: channel)
            case .repeating:
                try await RepeatingReasoningModel.Executor.writeReasoning(
                    AnswerLimitsModel.repeatingScript, into: channel)
                await Self.send(AnswerLimitsModel.answerText, usage: AnswerLimitsModel.smallUsage, into: channel)
            case .answer:
                await Self.send(AnswerLimitsModel.answerText, usage: AnswerLimitsModel.smallUsage, into: channel)
            case nil:
                await Self.send(AnswerLimitsModel.unscriptedText, usage: AnswerLimitsModel.smallUsage, into: channel)
            }
        }

        /// Sends `text` as one response entry of its own, and `usage` as the
        /// usage of the call.
        ///
        /// - Parameters:
        ///   - text: The response text.
        ///   - usage: The usage of the call.
        ///   - channel: The generation channel this call emits into.
        private static func send(
            _ text: String, usage: MeteredGenerationCall, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await CeilingStopCompactionModel.Executor.send(
                text: text, entryID: "response-\(UUID().uuidString)", usage: usage, into: channel)
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs an
/// ``AnswerLimitsModel``, with an auto-compaction budget and a repetition
/// detection.
struct AnswerLimitsSessionFixture {
    /// The limit of ``budget``, in tokens: small, so one scripted call can
    /// cross the trigger.
    private static let budgetLimit = 1_000

    /// The trigger of ``budget``, as a fraction of ``budgetLimit``.
    private static let budgetTrigger = 0.8

    /// The target of ``budget``, as a fraction of ``budgetLimit``.
    private static let budgetTarget = 0.5

    /// The budget of each session.
    static let budget = TokenBudget(limit: budgetLimit, trigger: budgetTrigger, target: budgetTarget)

    /// The window of the repetition detection, in tokens: small, so one
    /// repeating call fills it.
    private static let window = 200

    /// The repetition recoveries of each answer: one, so one answer uses all
    /// of its recoveries.
    private static let recoveriesPerAnswer = 1

    /// The repetition detection of each session.
    static let detection = RepetitionDetection(windowTokens: window, recoveriesPerAnswer: recoveriesPerAnswer)

    /// The vended session a test drives its answers on.
    let session: RoutedSession

    /// The script that the model of the session plays.
    let script: AnswerLimitsScript

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router and vends a session over an ``AnswerLimitsModel``.
    ///
    /// - Parameter tempDirPrefix: The calling suite's name, so a leaked temp
    ///   directory is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(tempDirPrefix: String) async throws -> AnswerLimitsSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let script = AnswerLimitsScript()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: AnswerLimitsModel(script: script)),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(budget: budget, repetitionDetection: detection))
        return AnswerLimitsSessionFixture(session: session, script: script, directory: directory)
    }

    /// Adds `steps` to the script, and runs one streamed answer with
    /// ``AnswerLimitsModel/ceiling``.
    ///
    /// - Parameters:
    ///   - steps: The steps of the model calls of the answer.
    ///   - prompt: The message of the answer.
    /// - Returns: The events of the answer, in order.
    /// - Throws: What the answer throws.
    func answer(playing steps: [AnswerLimitsStep], to prompt: String) async throws -> [SessionEvent] {
        script.add(steps)
        return try await collect(session.streamEvents(to: prompt, maxTokens: AnswerLimitsModel.ceiling))
    }
}
