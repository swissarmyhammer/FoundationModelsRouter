import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^hm9trt5: a pass whose reasoning goes past
/// ``RepetitionDetection/reasoningTokenLimit`` stops, and a recovery tells
/// the model to act.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RepeatingReasoningModel``. No GPU is in the loop. The session's
/// counter is the ``CharacterTokenCounter``: one token per character.
@Suite("A pass whose reasoning goes past the limit is stopped and recovered")
struct ReasoningTokenLimitTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ReasoningTokenLimitTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the failing test"

    /// The reasoning of a pass that goes past the default limit, in tokens.
    private static let longReasoningTokens = 10_000

    /// The reasoning of a pass that stays below the default limit, in tokens.
    private static let shortReasoningTokens = 2_000

    /// The hold of a call that the session must stop. It ends only when the
    /// session cancels it, or the test fails on the answer that follows.
    private static let stoppedHold = Duration.seconds(5)

    /// The hold of a call that the session must not stop: long enough for
    /// the watch to read the whole reasoning.
    private static let unstoppedHold = Duration.milliseconds(200)

    /// The line feed after each reasoning line.
    private static let lineFeed = "\n"

    /// Lines that are all new, whose text with a line feed after each one
    /// holds at least `tokens` characters: one token per character.
    ///
    /// Each line differs in its letters, not only in its digits, so the
    /// repetition detector reads each one as new.
    ///
    /// - Parameter tokens: The least number of tokens of the lines.
    /// - Returns: The lines, in order.
    private static func newLines(totalling tokens: Int) -> [String] {
        var lines: [String] = []
        var total = 0
        while total < tokens {
            let line = "Step \(DigitFreeLabel.spelling(lines.count)): the model reads one more part of the parser."
            lines.append(line)
            total += line.count + lineFeed.count
        }
        return lines
    }

    /// Runs one streamed answer over a fresh fixture.
    ///
    /// - Parameters:
    ///   - script: What the first call writes.
    ///   - detection: The repetition detection of the session.
    ///   - tools: The tools the session mounts.
    ///   - logger: The explicit logger of the session, or `nil` for the
    ///     loggers of the module.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAnswer(
        script: RepeatingReasoningScript,
        detection: RepetitionDetection = RepetitionDetection(),
        tools: [any Tool] = [],
        logger: Logger? = nil
    ) async throws -> (fixture: RepeatingReasoningSessionFixture, events: [SessionEvent]) {
        let fixture = try await RepeatingReasoningSessionFixture.make(
            script: script, repeatsAfterStop: false, detection: detection, tools: tools,
            tempDirPrefix: tempDirPrefix)
        if let logger {
            await fixture.session.useCaptureLogger(for: logger)
        }
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        return (fixture, events)
    }

    /// The finish reason of each ended submission among `events`, in order.
    private static func finishReasons(in events: [SessionEvent]) -> [FinishReason] {
        events.submissionEnds.map(\.finishReason)
    }

    /// The joined text of every `.reasoning` entry of `transcript`.
    private static func reasoningTexts(of transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return WatchedText.text(of: reasoning.segments)
        }
    }

    @Test("a reasoning of 10,000 tokens of new lines stops at the limit, and the recovery prompt reaches the model")
    func longReasoningStopsAndRecovers() async throws {
        let script = RepeatingReasoningScript(
            reasoningLines: Self.newLines(totalling: Self.longReasoningTokens), hold: Self.stoppedHold)
        let ((fixture, events), logs) = try await TelemetryCapture.run(forbidding: []) { context in
            let answer = try await Self.runAnswer(script: script, logger: context.logger)
            return (answer, context)
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let limit = RepetitionDetection.defaultReasoningTokenLimit
        let stop = try #require(events.reasoningStops.first)
        #expect(events.reasoningStops.count == 1)
        #expect(events.repetitionStops.isEmpty)
        #expect(stop.reasoningTokens >= limit)
        #expect(stop.reasoningTokens < Self.longReasoningTokens)
        #expect(stop.limit == limit)
        #expect(stop.passFinishReason == .reasoningTokenLimit)
        #expect(stop.recovery == 1)
        #expect(Self.finishReasons(in: events) == [.reasoningTokenLimit, .completed])
        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))

        let renders = fixture.log.renders
        #expect(renders.count == 2)
        let recovery = try #require(renders.last)
        #expect(recovery.promptTexts.last == RoutedSessionActor.reasoningStopContinuationPrompt)
        let keptReasoning = try #require(Self.reasoningTexts(of: recovery).first)
        #expect(keptReasoning.hasPrefix(try #require(script.reasoningLines.first)))

        #expect(stop.description.contains("reasoningTokenLimit = \(limit)"))
        logs.expectLogged(
            containing: "reasoning stop",
            metadata: [RouterTelemetry.LogMetadataKey.reasoningStop: stop.description])
    }

    @Test("a reasoning below the limit that ends in a tool call is not stopped")
    func shortReasoningWithToolCallIsNotStopped() async throws {
        let runs = RunCount()
        let script = RepeatingReasoningScript(
            reasoningLines: Self.newLines(totalling: Self.shortReasoningTokens), hold: Self.unstoppedHold,
            ending: .toolCall)

        let (fixture, events) = try await Self.runAnswer(script: script, tools: [CountingRunCodeTool(runs: runs)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.isEmpty)
        #expect(runs.value == 1)
        #expect(Self.finishReasons(in: events) == [.completed])
        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))
    }

    @Test("with no recovery left, the answer ends with the finish reason reasoningTokenLimit")
    func noRecoveryLeftEndsWithNamedFinishReason() async throws {
        let script = RepeatingReasoningScript(
            reasoningLines: Self.newLines(totalling: Self.longReasoningTokens), hold: Self.stoppedHold)

        let (fixture, events) = try await Self.runAnswer(
            script: script, detection: RepetitionDetection(recoveriesPerAnswer: 0))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(events.reasoningStops.first)
        #expect(events.reasoningStops.count == 1)
        #expect(stop.recovery == nil)
        #expect(Self.finishReasons(in: events) == [.reasoningTokenLimit])
        #expect(fixture.log.renders.count == 1)
        #expect(events.answers.count == 1)
    }

    @Test("a limit of nil or zero sets no limit", arguments: [nil, 0] as [Int?])
    func absentLimitDoesNotStop(limit: Int?) async throws {
        let script = RepeatingReasoningScript(
            reasoningLines: Self.newLines(totalling: Self.longReasoningTokens), hold: Self.unstoppedHold)

        let (fixture, events) = try await Self.runAnswer(
            script: script, detection: RepetitionDetection(reasoningTokenLimit: limit))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.isEmpty)
        #expect(Self.finishReasons(in: events) == [.completed])
        #expect(fixture.log.renders.count == 1)
    }
}

/// Task ^hm9trt5: a pass that ends inside its reasoning, at its ceiling or
/// before it, runs the recovery and does not end the answer.
///
/// Each test drives a real `LanguageModelSession` over a
/// ``CeilingProbeLanguageModel``, whose executor sends the channel actions of
/// the MLX executor.
@Suite("A pass that ends inside its reasoning runs the recovery")
struct ReasoningEndRecoveryTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ReasoningEndRecoveryTests"

    /// A ceiling the caller names, smaller than the context of the session.
    private static let requestedCeiling = 256

    /// Drives one answer through ``RoutedSession/streamEvents(to:maxTokens:)``
    /// under ``requestedCeiling``.
    ///
    /// - Parameter ending: How each generation call of the probe ends.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAnswer(
        ending: CeilingProbeEnding
    ) async throws -> (fixture: CeilingProbeSessionFixture, events: [SessionEvent]) {
        let fixture = try await CeilingProbeSessionFixture.make(ending: ending, tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: "fix the bug", maxTokens: requestedCeiling))
        return (fixture, events)
    }

    @Test(
        "a first pass that ends inside the reasoning recovers, and the answer completes",
        arguments: [
            (CeilingProbeEnding.truncatedOnFirstCallOnly, FinishReason.endedInsideReasoning),
            (CeilingProbeEnding.truncatedAtCeilingOnFirstCallOnly, FinishReason.maxTokens),
        ])
    func passEndedInsideReasoningRecovers(ending: CeilingProbeEnding, firstReason: FinishReason) async throws {
        let (fixture, events) = try await Self.runAnswer(ending: ending)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(events.reasoningStops.first)
        #expect(events.reasoningStops.count == 1)
        #expect(stop.passFinishReason == firstReason)
        #expect(stop.recovery == 1)
        #expect(stop.reasoningTokens > 0)
        #expect(stop.limit == (firstReason == .maxTokens ? Self.requestedCeiling : nil))
        #expect(events.submissionEnds.map(\.finishReason) == [firstReason, .completed])
        #expect(events.submissionStarts.map(\.cause) == [.message, .continuation])
        #expect(events.streamedText.contains(CeilingProbeLanguageModel.Executor.answerText))
    }

    @Test("a pass that always ends inside the reasoning recovers the configured number of times, then ends")
    func recoveriesEndAtTheConfiguredCount() async throws {
        let (fixture, events) = try await Self.runAnswer(ending: .truncatedInsideReasoning)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let recoveries = RepetitionDetection.defaultRecoveriesPerAnswer
        #expect(events.reasoningStops.map(\.recovery) == Array(1...recoveries).map(Optional.some) + [nil])
        #expect(
            events.submissionEnds.map(\.finishReason)
                == Array(repeating: .endedInsideReasoning, count: recoveries + 1))
        #expect(fixture.log.requestedCeilings.count == recoveries + 1)
        #expect(events.answers.count == 1)
    }
}

/// The reading of the last pass of an attempt that finds a pass that wrote
/// only reasoning (task ^hm9trt5).
@Suite("The last pass of an attempt is read for reasoning with no action")
struct ReasoningOnlyOutputTests {
    /// The reasoning text of the entries of this suite.
    private static let thought = "Let me think about the parser."

    /// The text of a reply.
    private static let reply = "The answer."

    /// A prompt entry.
    private static func prompt() -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "fix it"))]))
    }

    /// A reasoning entry with ``thought``.
    private static func reasoning() -> Transcript.Entry {
        .reasoning(Transcript.Reasoning(segments: [.text(Transcript.TextSegment(content: thought))]))
    }

    /// A response entry with `text`.
    ///
    /// - Parameter text: The response text.
    private static func response(_ text: String) -> Transcript.Entry {
        .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// A tool-calls entry with one call.
    private static func toolCalls() -> Transcript.Entry {
        .toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1", toolName: "search", arguments: GeneratedContent(properties: [:]))
                ]))
    }

    /// A tool-output entry that answers the call of ``toolCalls()``.
    private static func toolOutput() -> Transcript.Entry {
        .toolOutput(
            Transcript.ToolOutput(
                id: "call-1", toolName: "search", segments: [.text(Transcript.TextSegment(content: "found"))]))
    }

    @Test("a pass of reasoning and an empty response wrote only reasoning")
    func reasoningWithEmptyResponseIsReasoningOnly() {
        let entries = [Self.prompt(), Self.reasoning(), Self.response("")]

        #expect(ReasoningOnlyOutput.trailingReasoningText(of: entries) == Self.thought)
    }

    @Test("a pass that wrote a reply and then reasoned acted")
    func replyBeforeReasoningActed() {
        let entries = [Self.prompt(), Self.response(Self.reply), Self.reasoning()]

        #expect(ReasoningOnlyOutput.trailingReasoningText(of: entries) == nil)
    }

    @Test("a pass that wrote a tool call acted")
    func toolCallActed() {
        let entries = [Self.prompt(), Self.reasoning(), Self.toolCalls()]

        #expect(ReasoningOnlyOutput.trailingReasoningText(of: entries) == nil)
    }

    @Test("only the pass after the last tool output counts")
    func passAfterToolOutputCounts() {
        let entries = [Self.prompt(), Self.toolCalls(), Self.toolOutput(), Self.reasoning(), Self.response("")]

        #expect(ReasoningOnlyOutput.trailingReasoningText(of: entries) == Self.thought)
    }

    @Test("a pass with no reasoning text wrote no reasoning")
    func emptyPassIsNotReasoningOnly() {
        #expect(ReasoningOnlyOutput.trailingReasoningText(of: [Self.prompt(), Self.response("")]) == nil)
    }
}

/// The count of the reasoning tokens in the detector (task ^hm9trt5). The
/// counter is the ``CharacterTokenCounter``: one token per character.
@Suite("The detector finds a reasoning entry in flight at the reasoning token limit")
struct ReasoningLimitFindingTests {
    /// The limit of the tests of this suite, in tokens.
    private static let limit = 100

    /// A line of 49 characters, with its line feed 50 tokens.
    private static let line = "The model reads one more part of the parser code."

    /// A text of complete lines whose tokens reach ``limit``.
    private static var textAtLimit: String {
        String(repeating: line + "\n", count: limit / (line.count + 1))
    }

    /// A detector with ``limit`` and a window that no test fills.
    private static func makeDetector() -> RepetitionDetector {
        RepetitionDetector(
            detection: RepetitionDetection(windowTokens: .max, reasoningTokenLimit: limit),
            tokenCounter: CharacterTokenCounter())
    }

    @Test("a reasoning entry in flight at the limit gives a finding")
    func reasoningInFlightAtLimitIsFound() {
        var detector = Self.makeDetector()

        _ = detector.observe([WatchedText(entryId: "r", text: Self.textAtLimit, isReasoning: true)])

        let expected = ReasoningLimitFinding(reasoningTokens: Self.limit, limit: Self.limit)
        #expect(detector.reasoningLimitFinding() == expected)
    }

    @Test("a reasoning entry that a response with text follows gives no finding")
    func reasoningFollowedByTextIsNotFound() {
        var detector = Self.makeDetector()

        _ = detector.observe([
            WatchedText(entryId: "r", text: Self.textAtLimit, isReasoning: true),
            WatchedText(entryId: "a", text: Self.line),
        ])

        #expect(detector.reasoningLimitFinding() == nil)
    }

    @Test("a response entry at the limit gives no finding")
    func responseAtLimitIsNotFound() {
        var detector = Self.makeDetector()

        _ = detector.observe([WatchedText(entryId: "a", text: Self.textAtLimit)])

        #expect(detector.reasoningLimitFinding() == nil)
    }
}

/// The stored form of ``RepetitionDetection/reasoningTokenLimit`` (task
/// ^hm9trt5).
@Suite("The reasoning token limit has a named default and a stored form")
struct ReasoningTokenLimitSettingTests {
    /// The key of the limit in the stored form.
    private static let key = "reasoningTokenLimit"

    @Test("the default is 8,192 tokens")
    func defaultIsTheProposedValue() {
        #expect(RepetitionDetection.defaultReasoningTokenLimit == 8_192)
        #expect(RepetitionDetection().reasoningTokenLimit == RepetitionDetection.defaultReasoningTokenLimit)
    }

    @Test("a stored form with no key decodes with the default")
    func absentKeyDecodesWithTheDefault() throws {
        let stored = try JSONEncoder().encode(RepetitionDetection(reasoningTokenLimit: nil))
        var object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object.keys.contains(Self.key))
        object.removeValue(forKey: Self.key)

        let decoded = try JSONDecoder().decode(
            RepetitionDetection.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.reasoningTokenLimit == RepetitionDetection.defaultReasoningTokenLimit)
    }

    @Test("a stored limit decodes as it was stored", arguments: [nil, 0, 4_096] as [Int?])
    func storedLimitRoundTrips(limit: Int?) throws {
        let detection = RepetitionDetection(reasoningTokenLimit: limit)

        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: JSONEncoder().encode(detection))

        #expect(decoded == detection)
    }
}
