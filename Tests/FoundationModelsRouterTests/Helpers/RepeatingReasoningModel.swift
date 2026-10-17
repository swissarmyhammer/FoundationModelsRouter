import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

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

/// What one call of a ``RepeatingReasoningModel`` does after its last
/// reasoning line, before it writes its ending.
enum RepeatingReasoningHold: Sendable, Hashable {
    /// The call writes its ending at once. Use it when nothing can stop the
    /// call: the session has no watch, or the call writes no reasoning.
    case noHold

    /// The call waits until the session stops it with a cancel. Nothing
    /// else ends the wait, so the call never writes its ending. Use it for a
    /// call that the session must stop: when the session does not stop the
    /// call, the answer does not end, and a stack of the test process shows
    /// the hang.
    case untilStopped

    /// The call waits until the test opens the gate, then writes its ending.
    /// Use it for a call that the session must not stop, under a detection
    /// that is enabled: the test opens the gate only after the watch of the
    /// session read the whole reasoning and found no stop
    /// (``RepeatingReasoningSessionFixture/answer(to:)``). So the call cannot
    /// end before that read, and a stop could only come from an earlier read.
    case untilOpened(ReasoningHoldGate)
}

/// The gate of a ``RepeatingReasoningHold/untilOpened(_:)`` hold: one call
/// waits on it, and the test opens it after the watch of the session read
/// the whole reasoning of the call.
///
/// Two gates are equal only when they are the same object, so two scripts
/// never share an executor through their gates.
final class ReasoningHoldGate: Sendable, Hashable {
    /// The event that opens the gate.
    private let opened = AwaitedEvent()

    /// Waits until the gate opens.
    ///
    /// - Throws: `CancellationError` when the task of the call is cancelled
    ///   before the gate opens: the session stopped the call.
    func wait() async throws {
        do {
            try await opened.wait()
        } catch {
            throw CancellationError()
        }
    }

    /// Opens the gate after the repetition watch of `session` read
    /// `reasoning` whole and found no stop.
    ///
    /// The watch stores each read that finds no stop in
    /// ``RoutedSessionActor/lastRepetitionWatchRead``, then signals
    /// ``RoutedSessionActor/repetitionWatchReads``. The call waits on the
    /// gate after its last line, so the transcript does not change after
    /// that read.
    ///
    /// - Parameters:
    ///   - session: The session whose watch reads the call.
    ///   - reasoning: The whole reasoning text of the call.
    /// - Throws: ``ConditionNeverHeld`` when the task is cancelled before the
    ///   watch read the whole reasoning.
    func open(afterWatchOf session: RoutedSessionActor, reads reasoning: String) async throws {
        try await session.repetitionWatchReads.wait(until: {
            session.lastRepetitionWatchRead.withLock { texts in
                texts.contains { $0.isReasoning && $0.text == reasoning }
            }
        })
        opened.signal()
    }

    /// Whether `lhs` and `rhs` are the same gate.
    ///
    /// - Parameters:
    ///   - lhs: One gate.
    ///   - rhs: The other gate.
    /// - Returns: `true` only for the same object.
    static func == (lhs: ReasoningHoldGate, rhs: ReasoningHoldGate) -> Bool {
        lhs === rhs
    }

    /// Hashes the identity of the gate.
    ///
    /// - Parameter hasher: The hasher to feed.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// The reasoning that one call of a ``RepeatingReasoningModel`` writes: the
/// lines in order, then a hold, then the ending.
struct RepeatingReasoningScript: Sendable, Hashable {
    /// The lines the call writes into its reasoning entry, in order. The
    /// model adds a line feed after each one.
    let reasoningLines: [String]

    /// What the call does after its last reasoning line.
    let hold: RepeatingReasoningHold

    /// What the call writes after the hold.
    var ending: RepeatingReasoningEnding = .answer

    /// The token count that each reasoning line reports to the session. The
    /// usage of a call sums these counts. Zero gives a call whose usage does
    /// not move, as the usage of a cancelled MLX call does not (task
    /// ^3anq1yz).
    var lineTokenCount = RepeatingReasoningModel.Executor.emittedTokenCount

    /// The whole reasoning text of the call: each line with its line feed.
    var reasoningText: String {
        reasoningLines.map { $0 + RepeatingReasoningModel.Executor.lineFeed }.joined()
    }

    /// Makes the lines `newLines`, then `cycle` repeated `cycleCount` times.
    ///
    /// - Parameters:
    ///   - newLines: The lines the call writes one time, first.
    ///   - cycle: The lines the call writes again and again after them.
    ///   - cycleCount: How many times the call writes `cycle`.
    ///   - hold: What the call does after its last line.
    /// - Returns: The script.
    static func repeating(
        newLines: [String], cycle: [String], cycleCount: Int, hold: RepeatingReasoningHold
    ) -> RepeatingReasoningScript {
        let repeated = (0..<cycleCount).flatMap { _ in cycle }
        return RepeatingReasoningScript(reasoningLines: newLines + repeated, hold: hold)
    }

    /// The script of a call whose reasoning of new lines reaches `limit`, and
    /// that then waits until the session stops it.
    ///
    /// The lines are the first lines of ``distinctLines(totalling:)``, up to
    /// the first line at which they reach `limit`. The call writes no line
    /// after that one. So the read of the watch that stops the call holds the
    /// same reasoning in each run, and the call cannot end before the stop.
    ///
    /// - Parameter limit: The reasoning token limit of the session.
    /// - Returns: The script.
    static func reasoningHeldAtLimit(
        _ limit: Int = RepetitionDetection.defaultReasoningTokenLimit
    ) -> RepeatingReasoningScript {
        RepeatingReasoningScript(reasoningLines: distinctLines(totalling: limit), hold: .untilStopped)
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
///   ``RoutedSessionActor/repetitionStopContinuationPrompt``,
///   ``RoutedSessionActor/reasoningStopContinuationPrompt`` or
///   ``RoutedSessionActor/finalPassPrompt`` when
///   ``repeatsAfterStop`` is `true`, plays ``script``: it writes the
///   reasoning lines one by one, does what ``RepeatingReasoningScript/hold``
///   names, and writes ``RepeatingReasoningScript/ending``;
/// - a continuation call when ``repeatsAfterStop`` is `false` answers with
///   ``Executor/answerText`` at once.
///
/// Each reasoning line goes into the transcript as one append, so an
/// observer of the live transcript can see the entry grow.
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
            configuration.log.record(reasoningLevel: request.contextOptions.reasoningLevel)
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

        /// The prompts of the continuation calls after a stop of the session:
        /// the two recoveries, and the final pass (task ^0dcsd3t).
        private static let continuationPrompts: Set<String> = [
            RoutedSessionActor.repetitionStopContinuationPrompt,
            RoutedSessionActor.reasoningStopContinuationPrompt,
            RoutedSessionActor.finalPassPrompt,
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
        static func sendToolCall(into channel: LanguageModelExecutorGenerationChannel) async {
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: toolCallId, name: CountingRunCodeTool.toolName,
                        action: .appendArguments(toolCallArguments, tokenCount: emittedTokenCount))))
        }

        /// Writes the reasoning lines of `script` one by one, then does what
        /// its hold names.
        ///
        /// - Parameters:
        ///   - script: The lines and the hold.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `CancellationError` when the session stops the call, and
        ///   always for a ``RepeatingReasoningHold/untilStopped`` hold.
        static func writeReasoning(
            _ script: RepeatingReasoningScript, into channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let entryID = "reasoning-\(UUID().uuidString)"
            for line in script.reasoningLines {
                try Task.checkCancellation()
                await channel.send(
                    .reasoning(
                        entryID: entryID, action: .appendText(line + lineFeed, tokenCount: script.lineTokenCount)))
            }
            try await hold(script.hold)
        }

        /// Does what `hold` names.
        ///
        /// - Parameter hold: The hold of the script.
        /// - Throws: `CancellationError` when the session stops the call, and
        ///   always for a ``RepeatingReasoningHold/untilStopped`` hold.
        private static func hold(_ hold: RepeatingReasoningHold) async throws {
            switch hold {
            case .noHold:
                return
            case .untilStopped:
                try await waitForStop()
            case .untilOpened(let gate):
                try await gate.wait()
            }
        }

        /// Waits until the session stops the call: the stop cancels the task
        /// of the call.
        ///
        /// No code sends the event that the wait is on, so only the cancel
        /// ends the wait.
        ///
        /// - Throws: `CancellationError`, always.
        private static func waitForStop() async throws {
            let neverSent = AwaitedEvent()
            try? await neverSent.wait()
            throw CancellationError()
        }
    }
}

/// A ``RepeatingReasoningModel`` turns its reasoning off for one call, as a
/// model with a chat template flag does (task ^0dcsd3t). The backend then
/// states ``ReasoningOffRequest/reasoningLevel`` on a call that asks for it,
/// and the log records the level.
extension RepeatingReasoningModel: ReasoningSwitchable {
    /// Always `true`.
    ///
    /// - Returns: `true`.
    func canTurnReasoningOff() async throws -> Bool {
        true
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``RepeatingReasoningModel``, with the log of the model and the recorder
/// that holds the recorded transcript of the session.
///
/// A test ends the fixture with ``SessionDirectoryFixture/end(opening:)``.
struct RepeatingReasoningSessionFixture: SessionDirectoryFixture {
    /// The vended session a test drives its answers on.
    let session: any RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into, which the end of the
    /// fixture removes.
    let directory: URL

    /// What the first call writes.
    let script: RepeatingReasoningScript

    /// Streams one answer to `prompt`, and collects its events.
    ///
    /// When the hold of ``script`` is a gate
    /// (``RepeatingReasoningHold/untilOpened(_:)``), a task opens the gate
    /// after the watch of the session read the whole reasoning of the call
    /// and found no stop. When the session stops the call before that read,
    /// the gate stays closed, the answer goes on with its recovery, and the
    /// task is cancelled at the end of the answer. So a wrong stop makes the
    /// test fail on its events, and does not make it wait forever.
    ///
    /// - Parameter prompt: The message of the answer.
    /// - Returns: The events of the answer, in order.
    /// - Throws: What the answer throws, or a failed requirement when the
    ///   session is not a ``RoutedSessionActor``.
    func answer(to prompt: String) async throws -> [SessionEvent] {
        guard case .untilOpened(let gate) = script.hold else {
            return try await collect(session.streamEvents(to: prompt))
        }
        let actor = try #require(session as? RoutedSessionActor)
        let reasoning = script.reasoningText
        let opener = Task { try await gate.open(afterWatchOf: actor, reads: reasoning) }
        defer { opener.cancel() }
        return try await collect(session.streamEvents(to: prompt))
    }

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
    /// - Throws: Whatever profile resolution throws. Before it throws, it
    ///   removes the temp directory.
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
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: tools, repetitionDetection: detection))
        return RepeatingReasoningSessionFixture(
            session: session, log: log, recorder: recorder, directory: directory, script: script)
    }
}
