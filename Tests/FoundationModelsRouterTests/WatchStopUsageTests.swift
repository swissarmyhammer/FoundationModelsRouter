import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^3anq1yz: after a watch stop, the fill of the stopped submission is
/// the size of the render that the next pass receives, and the stopped call
/// is reported as a generation call with its fed and generated tokens.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``RepeatingReasoningModel``. The executor sends no usage update, so
/// the usage of a stopped call has no fed tokens, and its generated tokens
/// are the token counts of its reasoning lines. The MLX executor sends its
/// one usage update only after a call completes, so the usage of a cancelled
/// MLX call does not move at all; a script with a line token count of zero
/// gives that case. The session's counter is the ``CharacterTokenCounter``:
/// one token per character, and no tokens for a reasoning entry.
@Suite("A watch stop measures the render that the next pass receives")
struct WatchStopUsageTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "WatchStopUsageTests"

    /// One sentence of the prompt.
    private static let promptSentence = "Read the failing test and the parser that it calls. "

    /// How many times the prompt holds ``promptSentence``: enough that the
    /// render is much larger than the output of the stopped pass.
    private static let promptSentenceCount = 80

    /// The prompt of every answer of this suite: a render of thousands of
    /// tokens before the stopped pass writes one token.
    private static var prompt: String {
        String(repeating: promptSentence, count: promptSentenceCount)
    }

    /// The reasoning of a pass that goes past the default reasoning limit,
    /// in tokens.
    private static let longReasoningTokens = 10_000

    /// The window of the repetition detection: small, so a short script
    /// fills it.
    private static let repetitionWindow = 200

    /// The lines a repeating call writes again and again, in tokens.
    private static let repetitionCycleTokens = 150

    /// How many times a repeating call writes its cycle: far more than one
    /// ``repetitionWindow`` of tokens.
    private static let repetitionCycleCount = 40

    /// The hold of a call that the session must stop. It ends only when the
    /// session cancels it, or the test fails on the answer that follows.
    private static let stoppedHold = Duration.seconds(5)

    /// A script whose reasoning goes past the default reasoning limit.
    private static var reasoningScript: RepeatingReasoningScript {
        RepeatingReasoningScript(
            reasoningLines: RepeatingReasoningScript.distinctLines(totalling: longReasoningTokens), hold: stoppedHold)
    }

    /// A script that writes a cycle of lines again and again.
    private static var repeatingScript: RepeatingReasoningScript {
        .repeating(
            newLines: [], cycle: RepeatingReasoningScript.distinctLines(totalling: repetitionCycleTokens),
            cycleCount: repetitionCycleCount, hold: stoppedHold)
    }

    /// One answer of this suite: the fixture, the events of the answer, and
    /// the context of the session.
    private struct Answer {
        /// The fixture the answer ran on.
        let fixture: RepeatingReasoningSessionFixture

        /// The events of the answer, in order.
        let events: [SessionEvent]

        /// The context of the session, in tokens.
        let contextTokens: Int
    }

    /// Runs one streamed answer over a fresh fixture.
    ///
    /// - Parameters:
    ///   - script: What the first call writes.
    ///   - detection: The repetition detection of the session.
    /// - Returns: The answer.
    private static func runAnswer(script: RepeatingReasoningScript, detection: RepetitionDetection) async throws
        -> Answer
    {
        let fixture = try await RepeatingReasoningSessionFixture.make(
            script: script, repeatsAfterStop: false, detection: detection, tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        let contextTokens = try #require(fixture.session as? RoutedSessionActor).contextTokens
        return Answer(fixture: fixture, events: events, contextTokens: contextTokens)
    }

    /// The size of the render that the recovery call received, without the
    /// continuation prompt that the recovery added, in tokens.
    ///
    /// - Parameter answer: An answer whose first call stopped.
    /// - Returns: The counted size of the render after the stop.
    private static func renderTokensAfterStop(of answer: Answer) throws -> Int {
        let recovery = try #require(answer.fixture.log.renders.last)
        #expect(answer.fixture.log.renders.count == 2)
        return try CharacterTokenCounter().count(Transcript(entries: recovery.dropLast()))
    }

    /// The reasoning that the recovery call received, in tokens: all that the
    /// stopped call wrote, because a reasoning stop cuts nothing.
    ///
    /// - Parameter answer: An answer whose first call stopped for its
    ///   reasoning.
    /// - Returns: The counted reasoning text of the render after the stop.
    private static func reasoningTokensAfterStop(of answer: Answer) throws -> Int {
        let recovery = try #require(answer.fixture.log.renders.last)
        return recovery.reduce(0) { total, entry in
            guard case .reasoning(let reasoning) = entry else { return total }
            return total + CharacterTokenCounter().count(WatchedText.text(of: reasoning.segments))
        }
    }

    /// The size of the render that the stopped call received, in tokens.
    ///
    /// - Parameter answer: An answer whose first call stopped.
    /// - Returns: The counted size of the first render.
    private static func renderTokensOfStoppedCall(of answer: Answer) throws -> Int {
        try CharacterTokenCounter().count(try #require(answer.fixture.log.renders.first))
    }

    /// Checks that the end of the stopped submission carries the fill of the
    /// render that the recovery call received.
    ///
    /// - Parameter answer: An answer whose first call stopped.
    private static func expectFillOfRenderAfterStop(of answer: Answer) throws {
        let renderTokens = try renderTokensAfterStop(of: answer)
        #expect(renderTokens >= prompt.count)
        let stoppedEnd = try #require(answer.events.submissionEnds.first)
        let expectedFill = Double(renderTokens) / Double(answer.contextTokens)
        #expect(stoppedEnd.usage?.contextFill == expectedFill)
    }

    /// Checks that the stopped call has a generation call event and a
    /// journal row with its fed and generated tokens, and that the usage of
    /// the answer holds them.
    ///
    /// - Parameters:
    ///   - answer: An answer whose first call stopped.
    ///   - finishReason: The finish reason of the stop.
    private static func expectStoppedCallReported(of answer: Answer, finishReason: FinishReason) async throws {
        let fedTokens = try renderTokensOfStoppedCall(of: answer)
        let calls = answer.events.generationCalls
        #expect(calls.count == 2)
        let stoppedCall = try #require(calls.first)
        #expect(stoppedCall.tokensIn == fedTokens)
        #expect(stoppedCall.tokensOut > 0)
        #expect(stoppedCall.finishReason == finishReason)

        let journalCalls = await answer.fixture.recorder.events.filter { $0.kind == .generationCall }
        #expect(journalCalls.map(\.tokensIn) == calls.map { Optional($0.tokensIn) })
        #expect(journalCalls.map(\.tokensOut) == calls.map { Optional($0.tokensOut) })

        let usage = try #require(answer.events.answers.first?.usage)
        #expect(usage.tokensIn == calls.map(\.tokensIn).reduce(0, +))
        #expect(usage.tokensOut == calls.map(\.tokensOut).reduce(0, +))
        #expect(answer.events.submissionEnds.first?.usage?.tokensIn == fedTokens)
    }

    @Test("after a reasoning stop, the fill of the stopped submission is the render that the recovery receives")
    func reasoningStopFillIsTheRender() async throws {
        let answer = try await Self.runAnswer(script: Self.reasoningScript, detection: RepetitionDetection())
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        #expect(answer.events.reasoningStops.count == 1)
        try Self.expectFillOfRenderAfterStop(of: answer)
    }

    @Test("after a reasoning stop, the stopped call is a generation call, and its fed tokens are in the answer usage")
    func reasoningStopReportsTheStoppedCall() async throws {
        let answer = try await Self.runAnswer(script: Self.reasoningScript, detection: RepetitionDetection())
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        #expect(answer.events.reasoningStops.count == 1)
        try await Self.expectStoppedCallReported(of: answer, finishReason: .reasoningTokenLimit)
    }

    @Test("when the usage of a stopped call does not move, the session counts its fed and generated tokens")
    func stoppedCallWithNoUsageIsCounted() async throws {
        var script = Self.reasoningScript
        script.lineTokenCount = 0
        let answer = try await Self.runAnswer(script: script, detection: RepetitionDetection())
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        #expect(answer.events.reasoningStops.count == 1)
        let stoppedCall = try #require(answer.events.generationCalls.first)
        #expect(stoppedCall.tokensOut == (try Self.reasoningTokensAfterStop(of: answer)))
        try await Self.expectStoppedCallReported(of: answer, finishReason: .reasoningTokenLimit)
    }

    @Test("after a repetition stop, the fill of the stopped submission is the render that the recovery receives")
    func repetitionStopFillIsTheRender() async throws {
        let answer = try await Self.runAnswer(
            script: Self.repeatingScript, detection: RepetitionDetection(windowTokens: Self.repetitionWindow))
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        #expect(answer.events.repetitionStops.count == 1)
        try Self.expectFillOfRenderAfterStop(of: answer)
    }

    @Test("after a repetition stop, the stopped call is a generation call, and its fed tokens are in the answer usage")
    func repetitionStopReportsTheStoppedCall() async throws {
        let answer = try await Self.runAnswer(
            script: Self.repeatingScript, detection: RepetitionDetection(windowTokens: Self.repetitionWindow))
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        #expect(answer.events.repetitionStops.count == 1)
        try await Self.expectStoppedCallReported(of: answer, finishReason: .repeatedLines)
    }

    @Test("when a call stopped for repetition reports no usage, the session counts its fed and generated tokens")
    func repetitionStopWithNoUsageIsCounted() async throws {
        var script = Self.repeatingScript
        script.lineTokenCount = 0
        let answer = try await Self.runAnswer(
            script: script, detection: RepetitionDetection(windowTokens: Self.repetitionWindow))
        defer { try? FileManager.default.removeItem(at: answer.fixture.directory) }

        let stop = try #require(answer.events.repetitionStops.first)
        #expect(answer.events.repetitionStops.count == 1)
        let stoppedCall = try #require(answer.events.generationCalls.first)
        // The output of the stopped pass holds each complete line that the
        // watch read before the stop, so the counted output is not smaller.
        #expect(stoppedCall.tokensOut >= stop.generatedTokens)
        try await Self.expectStoppedCallReported(of: answer, finishReason: .repeatedLines)
    }
}
