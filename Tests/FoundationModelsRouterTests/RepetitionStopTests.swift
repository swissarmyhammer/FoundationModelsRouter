import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^1hcwaqy: a generate call whose share of new lines goes to zero and
/// stays there is stopped, recovered a bounded number of times, and kept out
/// of the render that the next call receives.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RepeatingReasoningModel``. No GPU is in the loop. The session's
/// counter is the ``CharacterTokenCounter``: one token per character.
@Suite("A generate call that repeats itself is stopped and recovered")
struct RepetitionStopTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "RepetitionStopTests"

    /// The prompt of every turn of this suite.
    private static let prompt = "fix the failing test"

    /// The window of the tests that stop: small, so a short script fills it.
    private static let window = 200

    /// The detection of the tests that stop: ``window``, and the default
    /// minimum line length and recoveries per answer.
    private static let detection = RepetitionDetection(windowTokens: window)

    /// The lines a call writes one time, before it repeats.
    private static let newLines = [
        "First I read the failing test and its fixture.",
        "The fixture builds the query with a stale alias.",
    ]

    /// The lines a call that repeats writes again and again.
    private static let cycle = [
        "Maybe the alias is resolved in the compiler.",
        "Let me look at how the compiler resolves it.",
        "So the compiler keeps the alias from the join.",
    ]

    /// How many times a call that repeats writes ``cycle``: far more than
    /// one ``window`` of tokens.
    private static let cycleCount = 40

    /// The hold of a call that the session must stop. It ends only when the
    /// session cancels it, or the test fails on the answer that follows.
    private static let stoppedHold = Duration.seconds(5)

    /// The hold of a call that the session must not stop: long enough for
    /// the watch to read the whole reasoning.
    private static let unstoppedHold = Duration.milliseconds(200)

    /// A script that writes ``newLines``, then ``cycle`` ``cycleCount`` times.
    private static func repeatingScript(hold: Duration) -> RepeatingReasoningScript {
        .repeating(newLines: newLines, cycle: cycle, cycleCount: cycleCount, hold: hold)
    }

    /// The reasoning text the render keeps after a stop: each new line one
    /// time, with its line feed.
    private static var keptReasoning: String {
        (newLines + cycle).map { $0 + "\n" }.joined()
    }

    /// Runs one streamed turn over a fresh fixture.
    ///
    /// - Parameters:
    ///   - script: What the first call writes.
    ///   - repeatsAfterStop: Whether a continuation call repeats again.
    ///   - detection: The repetition detection of the session.
    /// - Returns: The fixture and the events of the turn, in order.
    private static func runTurn(
        script: RepeatingReasoningScript, repeatsAfterStop: Bool, detection: RepetitionDetection
    ) async throws -> (fixture: RepeatingReasoningSessionFixture, events: [SessionEvent]) {
        let fixture = try await RepeatingReasoningSessionFixture.make(
            script: script, repeatsAfterStop: repeatsAfterStop, detection: detection,
            tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        return (fixture, events)
    }

    /// The finish reason of each ended submission among `events`, in order.
    /// Each end also carries the same reason in its usage.
    private static func finishReasons(in events: [SessionEvent]) -> [FinishReason] {
        let ends = events.submissionEnds
        #expect(ends.map { $0.usage?.finishReason } == ends.map(\.finishReason))
        return ends.map(\.finishReason)
    }

    /// The repetition stops among `events`, in order.
    private static func stops(in events: [SessionEvent]) -> [RepetitionStop] {
        events.compactMap { event in
            guard case .repetitionStopped(let stop) = event else { return nil }
            return stop
        }
    }

    /// The joined text of every `.reasoning` entry of `transcript`.
    private static func reasoningText(of transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }

    @Test("a call whose new-line share stays at zero for one window stops, with a log line and an event record")
    func repeatingCallStopsWithLogAndEvent() async throws {
        let start = Date()
        let (fixture, events) = try await Self.runTurn(
            script: Self.repeatingScript(hold: Self.stoppedHold), repeatsAfterStop: false, detection: Self.detection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(Self.stops(in: events).first)
        #expect(stop.tokensWithoutNewLine >= Self.window)
        #expect(stop.generatedTokens >= stop.tokensWithoutNewLine)
        #expect(stop.newLines == Self.newLines.count + Self.cycle.count)
        #expect(stop.countedLines > stop.newLines)
        #expect(stop.newLineShare == Double(stop.newLines) / Double(stop.countedLines))
        #expect(stop.detection == Self.detection)
        #expect(stop.recovery == 1)
        #expect(Self.finishReasons(in: events) == [.repeatedLines, .completed])
        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))
        let namedValues = [
            "generated \(stop.generatedTokens) tokens",
            "isEnabled = true",
            "windowTokens = \(Self.window)",
            "minimumLineLength = \(RepetitionDetection.defaultMinimumLineLength)",
            "recoveriesPerAnswer = \(RepetitionDetection.defaultRecoveriesPerAnswer)",
        ]
        for value in namedValues {
            #expect(stop.description.contains(value), "the log line does not name \(value)")
        }
        try assertLogged(containing: stop.description, since: start)
    }

    @Test("normal reasoning with many repeated short lines is not stopped")
    func repeatedShortLinesDoNotStop() async throws {
        let shortLines = ["```", "\"\"\"", ")", "..."]
        let longLines = (0..<Self.cycleCount).map { index in "Step \(index): check the next branch of the parser." }
        let lines = longLines.flatMap { line in [line] + Array(repeating: shortLines, count: Self.cycleCount).flatMap { $0 } }
        let script = RepeatingReasoningScript(reasoningLines: lines, hold: Self.unstoppedHold)

        let (fixture, events) = try await Self.runTurn(script: script, repeatsAfterStop: false, detection: Self.detection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(Self.stops(in: events).isEmpty)
        #expect(Self.finishReasons(in: events) == [.completed])
        #expect(events.streamedText.contains(RepeatingReasoningModel.Executor.answerText))
    }

    @Test("after a stop, the next call does not receive the repeated part, and the record keeps the full entry")
    func repeatedPartLeavesTheRenderAndStaysInTheRecord() async throws {
        let (fixture, events) = try await Self.runTurn(
            script: Self.repeatingScript(hold: Self.stoppedHold), repeatsAfterStop: false, detection: Self.detection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(Self.stops(in: events).count == 1)

        let renders = fixture.log.renders
        #expect(renders.count == 2)
        let continuation = try #require(renders.last)
        #expect(continuation.promptTexts.last == RoutedSessionActor.repetitionStopContinuationPrompt)
        #expect(Self.reasoningText(of: continuation) == [Self.keptReasoning])

        let recordedReasoning = await fixture.recorder.events.filter { $0.kind == .reasoning }.compactMap(\.text)
        let recorded = try #require(recordedReasoning.first)
        #expect(recordedReasoning.count == 1)
        #expect(recorded.hasPrefix(Self.keptReasoning))
        #expect(recorded.count > Self.keptReasoning.count + Self.window)
    }

    @Test("recoveries stop at the configured number per answer")
    func recoveriesStopAtTheConfiguredCount() async throws {
        let (fixture, events) = try await Self.runTurn(
            script: Self.repeatingScript(hold: Self.stoppedHold), repeatsAfterStop: true, detection: Self.detection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let recoveries = RepetitionDetection.defaultRecoveriesPerAnswer
        let stops = Self.stops(in: events)
        #expect(stops.count == recoveries + 1)
        #expect(stops.map(\.recovery) == Array(1...recoveries).map(Optional.some) + [nil])
        #expect(Self.finishReasons(in: events) == Array(repeating: .repeatedLines, count: recoveries + 1))
        #expect(fixture.log.renders.count == recoveries + 1)
        // The first submission delivers the message. Each recovery is one
        // continuation submission of the same chain, and the chain has one
        // answer.
        let causes = events.submissionStarts.map(\.cause)
        #expect(causes == [.message] + Array(repeating: .continuation, count: recoveries))
        _ = eventsInsideAnswerFrame(events)
        #expect(events.answers.count == 1)
    }

    @Test("a detection that is not enabled does not stop a call that repeats")
    func disabledDetectionDoesNotStop() async throws {
        var detection = Self.detection
        detection.isEnabled = false

        let (fixture, events) = try await Self.runTurn(
            script: Self.repeatingScript(hold: Self.unstoppedHold), repeatsAfterStop: false, detection: detection)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(Self.stops(in: events).isEmpty)
        #expect(Self.finishReasons(in: events) == [.completed])
        #expect(fixture.log.renders.count == 1)
    }
}

/// The defaults of ``RepetitionDetection`` are the values the user confirmed
/// (task ^1hcwaqy), and a value the host does not pass keeps its default.
@Suite("The repetition detection has named defaults a host can change")
struct RepetitionDetectionDefaultTests {
    @Test("the defaults are 2,048 tokens, 20 characters, 2 recoveries, and on")
    func defaultsAreTheConfirmedValues() {
        #expect(RepetitionDetection.defaultWindowTokens == 2_048)
        #expect(RepetitionDetection.defaultMinimumLineLength == 20)
        #expect(RepetitionDetection.defaultRecoveriesPerAnswer == 2)
        #expect(RepetitionDetection.defaultIsEnabled)

        let detection = RepetitionDetection()
        #expect(detection.windowTokens == RepetitionDetection.defaultWindowTokens)
        #expect(detection.minimumLineLength == RepetitionDetection.defaultMinimumLineLength)
        #expect(detection.recoveriesPerAnswer == RepetitionDetection.defaultRecoveriesPerAnswer)
        #expect(detection.isEnabled == RepetitionDetection.defaultIsEnabled)
    }

    @Test("a session configuration that names no detection carries the default")
    func sessionConfigurationDefaultsToTheDefaultDetection() {
        #expect(SessionConfiguration().repetitionDetection == RepetitionDetection())
    }

    @Test("a value the host passes replaces its default, and the others keep theirs")
    func passedValueReplacesOnlyItsDefault() {
        let detection = RepetitionDetection(recoveriesPerAnswer: 0)
        #expect(detection.recoveriesPerAnswer == 0)
        #expect(detection.windowTokens == RepetitionDetection.defaultWindowTokens)
        #expect(detection.minimumLineLength == RepetitionDetection.defaultMinimumLineLength)
        #expect(detection.isEnabled)
    }

    @Test("the sidecar configuration keeps the detection the session was made with")
    func persistableKeepsTheDetection() throws {
        let detection = RepetitionDetection(isEnabled: false, windowTokens: 512, minimumLineLength: 8, recoveriesPerAnswer: 1)
        let persistable = SessionConfiguration(repetitionDetection: detection).persistable
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONEncoder().encode(persistable))
        #expect(decoded.repetitionDetection == detection)
    }
}
