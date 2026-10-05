import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// How one call of a ``RepeatingReasoningModel`` that plays its script ends
/// after the hold (task ^hm9trt5).
enum RepeatingReasoningEnding: Sendable, Hashable {
    /// The call answers with ``RepeatingReasoningModel/Executor/answerText``.
    case answer

    /// The call asks for one ``CountingRunCodeTool`` call. The next call,
    /// whose transcript holds the tool output, answers.
    case toolCall
}

/// The reasoning that one call of a ``RepeatingReasoningModel`` writes: the
/// lines in order, then a hold, then the ending.
struct RepeatingReasoningScript: Sendable, Hashable {
    /// The lines the call writes into its reasoning entry, in order. The
    /// model adds a line feed after each one.
    let reasoningLines: [String]

    /// How long the call waits after its last reasoning line, before it
    /// writes the ending. A stop of the session cancels the wait.
    let hold: Duration

    /// What the call writes after the hold.
    var ending: RepeatingReasoningEnding = .answer

    /// The token count that each reasoning line reports to the session. The
    /// usage of a call sums these counts. Zero gives a call whose usage does
    /// not move, as the usage of a cancelled MLX call does not (task
    /// ^3anq1yz).
    var lineTokenCount = RepeatingReasoningModel.Executor.emittedTokenCount

    /// Makes the lines `newLines`, then `cycle` repeated `cycleCount` times.
    ///
    /// - Parameters:
    ///   - newLines: The lines the call writes one time, first.
    ///   - cycle: The lines the call writes again and again after them.
    ///   - cycleCount: How many times the call writes `cycle`.
    ///   - hold: How long the call waits after its last line.
    /// - Returns: The script.
    static func repeating(
        newLines: [String], cycle: [String], cycleCount: Int, hold: Duration
    ) -> RepeatingReasoningScript {
        let repeated = (0..<cycleCount).flatMap { _ in cycle }
        return RepeatingReasoningScript(reasoningLines: newLines + repeated, hold: hold)
    }

    /// Lines that are all new, whose text with a line feed after each one
    /// holds at least `tokens` characters: one token per character under the
    /// ``CharacterTokenCounter``.
    ///
    /// Each line differs in its letters, not only in its digits, so the
    /// repetition detector reads each one as new.
    ///
    /// - Parameter tokens: The least number of tokens of the lines.
    /// - Returns: The lines, in order.
    static func distinctLines(totalling tokens: Int) -> [String] {
        var lines: [String] = []
        var total = 0
        while total < tokens {
            let line = "Step \(DigitFreeLabel.spelling(lines.count)): the model reads one more part of the parser."
            lines.append(line)
            total += line.count + RepeatingReasoningModel.Executor.lineFeed.count
        }
        return lines
    }
}

/// A deterministic `LanguageModel` whose calls write a reasoning entry that
/// can repeat itself (task ^1hcwaqy).
///
/// Each executor call records the transcript it receives in ``log``, then:
///
/// - a call whose transcript holds a tool output answers with
///   ``Executor/answerText`` at once;
/// - the first call of the session, and each call whose prompt is
///   ``RoutedSessionActor/repetitionStopContinuationPrompt`` or
///   ``RoutedSessionActor/reasoningStopContinuationPrompt`` when
///   ``repeatsAfterStop`` is `true`, plays ``script``: it writes the
///   reasoning lines one by one, waits for ``RepeatingReasoningScript/hold``,
///   and writes ``RepeatingReasoningScript/ending``;
/// - a continuation call when ``repeatsAfterStop`` is `false` answers with
///   ``Executor/answerText`` at once.
///
/// Each reasoning line goes into the transcript as one append, and the call
/// yields after each one, so an observer of the live transcript sees the
/// entry grow.
struct RepeatingReasoningModel: LanguageModel {
    /// The log that records the transcript of each call.
    let log: RenderProbeLog

    /// What the first call writes.
    let script: RepeatingReasoningScript

    /// Whether a continuation call after a stop plays ``script`` again.
    let repeatsAfterStop: Bool

    /// Declares reasoning, because each call writes a reasoning entry, and
    /// tool calling, because a script can end with a tool call.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning, .toolCalling]) }

    /// Builds the executor cache key from the log, the script and the flag.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, script: script, repeatsAfterStop: repeatsAfterStop)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records the transcript of each call.
            let log: RenderProbeLog

            /// What a call that repeats writes.
            let script: RepeatingReasoningScript

            /// Whether a continuation call after a stop repeats again.
            let repeatsAfterStop: Bool

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.script == rhs.script && lhs.repeatsAfterStop == rhs.repeatsAfterStop
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(script)
                hasher.combine(repeatsAfterStop)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = RepeatingReasoningModel

        /// The answer text of a call that ends.
        static let answerText = "The answer, after the reasoning."

        /// The token count every emitted fragment reports, unless the script
        /// names another count for its reasoning lines.
        static let emittedTokenCount = 1

        /// The line feed the model writes after each reasoning line.
        static let lineFeed = "\n"

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log, the script and the flag.
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
            model: RepeatingReasoningModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(render: request.transcript)
            if playsScript(request.transcript) {
                try await Self.writeReasoning(configuration.script, into: channel)
                if configuration.script.ending == .toolCall {
                    await Self.sendToolCall(into: channel)
                    return
                }
            }
            await channel.send(
                .response(
                    entryID: "answer-\(UUID().uuidString)",
                    action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
        }

        /// The prompts of the continuation calls after a stop of the session.
        private static let continuationPrompts: Set<String> = [
            RoutedSessionActor.repetitionStopContinuationPrompt,
            RoutedSessionActor.reasoningStopContinuationPrompt,
        ]

        /// The arguments of the one tool call of a ``RepeatingReasoningEnding/toolCall`` script.
        private static let toolCallArguments = #"{"code": "print(value)"}"#

        /// The id of the one tool call of a ``RepeatingReasoningEnding/toolCall`` script.
        private static let toolCallId = "reasoning-run-code-call"

        /// Whether a call over `transcript` plays ``Configuration/script``: the
        /// transcript holds no tool output, and the call is not a continuation
        /// after a stop, or a continuation repeats.
        ///
        /// - Parameter transcript: The transcript of the call.
        /// - Returns: `true` when the call plays the script.
        private func playsScript(_ transcript: Transcript) -> Bool {
            let holdsToolOutput = transcript.contains { entry in
                guard case .toolOutput = entry else { return false }
                return true
            }
            let isContinuation = transcript.promptTexts.last.map(Self.continuationPrompts.contains) ?? false
            return !holdsToolOutput && (!isContinuation || configuration.repeatsAfterStop)
        }

        /// Sends one ``CountingRunCodeTool`` call with ``toolCallArguments``.
        ///
        /// - Parameter channel: The generation channel this call emits into.
        private static func sendToolCall(into channel: LanguageModelExecutorGenerationChannel) async {
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: toolCallId, name: CountingRunCodeTool.toolName,
                        action: .appendArguments(toolCallArguments, tokenCount: emittedTokenCount))))
        }

        /// Writes the reasoning lines of `script` one by one, then waits for
        /// its hold.
        ///
        /// - Parameters:
        ///   - script: The lines and the hold.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `CancellationError` when the session stops the call.
        static func writeReasoning(
            _ script: RepeatingReasoningScript, into channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let entryID = "reasoning-\(UUID().uuidString)"
            for line in script.reasoningLines {
                try Task.checkCancellation()
                await channel.send(
                    .reasoning(
                        entryID: entryID, action: .appendText(line + lineFeed, tokenCount: script.lineTokenCount)))
                await Task.yield()
            }
            try await Task.sleep(for: script.hold)
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``RepeatingReasoningModel``, with the log of the model and the recorder
/// that holds the recorded transcript of the session.
struct RepeatingReasoningSessionFixture {
    /// The vended session a test drives its answers on.
    let session: RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router and vends a session over a ``RepeatingReasoningModel``
    /// with `detection`.
    ///
    /// - Parameters:
    ///   - script: What the first call writes.
    ///   - repeatsAfterStop: Whether a continuation call repeats again.
    ///   - detection: The repetition detection the session is made with.
    ///   - tools: The tools the session mounts.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        script: RepeatingReasoningScript,
        repeatsAfterStop: Bool,
        detection: RepetitionDetection,
        tools: [any Tool] = [],
        tempDirPrefix: String
    ) async throws -> RepeatingReasoningSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let log = RenderProbeLog()
        let model = RepeatingReasoningModel(log: log, script: script, repeatsAfterStop: repeatsAfterStop)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: tools, repetitionDetection: detection))
        return RepeatingReasoningSessionFixture(session: session, log: log, recorder: recorder, directory: directory)
    }
}
