import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^0dcsd3t: the recovery after a reasoning stop or a repetition stop
/// runs with the reasoning of the model off, the render closes the stopped
/// reasoning, the answer never ends with an empty text, and the journal and
/// the answer report each stop.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a scripted model. No GPU is in the loop. The session's counter is the
/// ``CharacterTokenCounter``: one token per character.
@Suite("A recovery after a watch stop acts, and the answer never ends with no output")
struct ReasoningStopRecoveryTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ReasoningStopRecoveryTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the failing test"

    /// The window of the tests that stop for repetition: small, so a short
    /// script fills it.
    private static let window = 200

    /// The detection of this suite: ``window``, and each other default.
    private static let detection = RepetitionDetection(windowTokens: window)

    /// The hold of a call that the session must stop. It ends only when the
    /// session cancels it, or the test fails on the answer that follows.
    private static let stoppedHold = Duration.seconds(5)

    /// The reasoning of a pass that goes past the default reasoning limit, in
    /// tokens.
    private static let longReasoningTokens = 10_000

    /// A ceiling the caller names for a ``CeilingProbeLanguageModel`` answer.
    private static let requestedCeiling = 256

    /// A script that writes two new lines, then three lines again and again.
    private static var repeatingScript: RepeatingReasoningScript {
        .repeating(
            newLines: [
                "First I read the failing test and its fixture.",
                "The fixture builds the query with a stale alias.",
            ],
            cycle: [
                "Maybe the alias is resolved in the compiler.",
                "Let me look at how the compiler resolves it.",
                "So the compiler keeps the alias from the join.",
            ],
            cycleCount: 40, hold: stoppedHold)
    }

    /// A script whose reasoning goes past the default reasoning limit with
    /// new lines only.
    private static var longReasoningScript: RepeatingReasoningScript {
        RepeatingReasoningScript(
            reasoningLines: RepeatingReasoningScript.distinctLines(totalling: longReasoningTokens), hold: stoppedHold)
    }

    /// A script whose call writes no reasoning and asks for one
    /// ``CountingRunCodeTool`` call at once.
    private static var toolCallScript: RepeatingReasoningScript {
        RepeatingReasoningScript(reasoningLines: [], hold: .zero, ending: .toolCall)
    }

    /// Runs one streamed answer over a ``StagedReasoningSessionFixture``.
    ///
    /// - Parameters:
    ///   - scripts: The script of each call, in call order.
    ///   - detection: The repetition detection of the session.
    ///   - tools: The tools the session mounts.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runStagedAnswer(
        scripts: [RepeatingReasoningScript],
        detection: RepetitionDetection = detection,
        tools: [any Tool] = []
    ) async throws -> (fixture: StagedReasoningSessionFixture, events: [SessionEvent]) {
        let fixture = try await StagedReasoningSessionFixture.make(
            scripts: scripts, detection: detection, tools: tools, tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        return (fixture, events)
    }

    /// Runs one streamed answer over a ``CeilingProbeSessionFixture`` under
    /// ``requestedCeiling``.
    ///
    /// - Parameter ending: How each generation call of the probe ends.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runProbeAnswer(
        ending: CeilingProbeEnding
    ) async throws -> (fixture: CeilingProbeSessionFixture, events: [SessionEvent]) {
        let fixture = try await CeilingProbeSessionFixture.make(ending: ending, tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt, maxTokens: requestedCeiling))
        return (fixture, events)
    }

    /// The watch stops that the journal of `recorder` records, in order.
    ///
    /// - Parameter recorder: The recorder of the session.
    /// - Returns: The decoded stops.
    private static func journaledStops(in recorder: InMemoryRecorder) async throws -> [WatchStop] {
        try await recorder.events.filter { $0.kind == .watchStop }.map { event in
            let payload = try #require(event.entry)
            let structure = try #require(payload.segments?.first?.persistedStructure)
            let segment = try #require(
                try WatchStopSegment(
                    schemaName: structure.schemaName, contentJSON: structure.contentJSON, id: payload.entryId))
            #expect(event.text == segment.content.description)
            return segment.content
        }
    }

    /// The `.response` entry right before the last `.prompt` entry of
    /// `transcript`, as its text, or `nil`.
    private static func responseTextBeforeLastPrompt(in transcript: Transcript) -> String? {
        let entries = Array(transcript)
        guard let lastPrompt = entries.lastIndex(where: { entry in
            if case .prompt = entry { return true }
            return false
        }), lastPrompt > entries.startIndex,
            case .response(let response) = entries[entries.index(before: lastPrompt)]
        else { return nil }
        return WatchedText.text(of: response.segments)
    }

    @Test("the recovery after a repetition stop asks the model to turn its reasoning off")
    func repetitionRecoveryRunsWithReasoningOff() async throws {
        let (fixture, events) = try await Self.runStagedAnswer(scripts: [Self.repeatingScript])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.repetitionStops.map(\.recovery) == [1])
        #expect(fixture.log.reasoningLevels == [nil, ReasoningOffRequest.reasoningLevel])
    }

    @Test("the recovery after a pass that ends inside its reasoning asks the model to turn its reasoning off")
    func reasoningEndRecoveryRunsWithReasoningOff() async throws {
        let (fixture, events) = try await Self.runProbeAnswer(ending: .truncatedOnFirstCallOnly)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.map(\.recovery) == [1])
        #expect(fixture.log.reasoningLevels == [nil, ReasoningOffRequest.reasoningLevel])
    }

    @Test("after a stop, only the recovery pass runs with the reasoning off, and the pass after its tool call reasons")
    func recoveryToolLoopTurnsReasoningBackOn() async throws {
        let runs = RunCount()
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: [Self.longReasoningScript, Self.toolCallScript], tools: [CountingRunCodeTool(runs: runs)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.map(\.recovery) == [1])
        #expect(runs.value == 1)
        #expect(fixture.log.reasoningLevels == [nil, ReasoningOffRequest.reasoningLevel, nil])
        #expect(events.answers.first?.reply == RepeatingReasoningModel.Executor.answerText)
    }

    @Test("only the first pass of the final pass runs with the reasoning off, and the pass after its tool call reasons")
    func finalPassToolLoopTurnsReasoningBackOn() async throws {
        let runs = RunCount()
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: [Self.longReasoningScript, Self.toolCallScript],
            detection: RepetitionDetection(recoveriesPerAnswer: 0),
            tools: [CountingRunCodeTool(runs: runs)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.map(\.recovery) == [nil])
        #expect(runs.value == 1)
        #expect(fixture.log.renders.dropFirst().first?.promptTexts.last == RoutedSessionActor.finalPassPrompt)
        #expect(fixture.log.reasoningLevels == [nil, ReasoningOffRequest.reasoningLevel, nil])
        #expect(events.answers.first?.reply == RepeatingReasoningModel.Executor.answerText)
    }

    @Test("a repetition stop, then reasoning stops, use all recoveries, and a final pass with reasoning off answers")
    func repetitionThenReasoningStopsEndWithFinalPass() async throws {
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: [Self.repeatingScript, Self.longReasoningScript, Self.longReasoningScript])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let off = ReasoningOffRequest.reasoningLevel
        #expect(events.repetitionStops.map(\.recovery) == [1])
        #expect(events.reasoningStops.map(\.recovery) == [2, nil])
        #expect(fixture.log.reasoningLevels == [nil, off, off, off])
        #expect(fixture.log.renders.last?.promptTexts.last == RoutedSessionActor.finalPassPrompt)

        let answer = try #require(events.answers.first)
        #expect(answer.reply == RepeatingReasoningModel.Executor.answerText)
        let stop = try #require(answer.stop)
        #expect(stop.kind == .reasoning)
        #expect(stop.limit == RepetitionDetection.defaultReasoningTokenLimit)
        #expect(stop.recovery == nil)
        #expect(stop.recoveriesUsed == RepetitionDetection.defaultRecoveriesPerAnswer)
        #expect(stop.recoveriesAllowed == RepetitionDetection.defaultRecoveriesPerAnswer)

        let journaled = try await Self.journaledStops(in: fixture.recorder)
        #expect(journaled.map(\.kind) == [.repetition, .reasoning, .reasoning])
        #expect(journaled.map(\.recovery) == [1, 2, nil])
        #expect(journaled.map(\.limit) == [Self.window, RepetitionDetection.defaultReasoningTokenLimit, RepetitionDetection.defaultReasoningTokenLimit])
        #expect(journaled.last == stop)
    }

    @Test("when the final pass gives no text either, the reply is a text that states the stop")
    func emptyFinalPassRepliesWithTheStop() async throws {
        let (fixture, events) = try await Self.runProbeAnswer(ending: .truncatedInsideReasoning)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let off = ReasoningOffRequest.reasoningLevel
        #expect(events.reasoningStops.map(\.recovery) == [1, 2, nil, nil])
        #expect(fixture.log.reasoningLevels == [nil, off, off, off])
        let lastStop = try #require(events.reasoningStops.last)
        let answer = try #require(events.answers.first)
        #expect(answer.reply == WatchStop(lastStop).stoppedAnswerText)
        #expect(answer.reply.contains("recoveries=2/2"))
        #expect(answer.stop == WatchStop(lastStop))
    }

    @Test("the render of a recovery closes the stopped reasoning before the prompt")
    func recoveryRenderClosesTheStoppedReasoning() async throws {
        let (fixture, events) = try await Self.runStagedAnswer(scripts: [Self.longReasoningScript])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.map(\.recovery) == [1])
        let recovery = try #require(fixture.log.renders.last)
        #expect(recovery.promptTexts.last == RoutedSessionActor.reasoningStopContinuationPrompt)
        #expect(Self.responseTextBeforeLastPrompt(in: recovery) == RoutedSessionActor.reasoningClosureText)
    }

    @Test("the render of a recovery after a pass that ended inside its reasoning closes that reasoning")
    func reasoningEndRenderClosesTheStoppedReasoning() async throws {
        let (fixture, events) = try await Self.runProbeAnswer(ending: .truncatedOnFirstCallOnly)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.reasoningStops.map(\.recovery) == [1])
        let journal = await fixture.session.transcript
        #expect(Self.responseTextBeforeLastPrompt(in: journal) == RoutedSessionActor.reasoningClosureText)
    }
}
