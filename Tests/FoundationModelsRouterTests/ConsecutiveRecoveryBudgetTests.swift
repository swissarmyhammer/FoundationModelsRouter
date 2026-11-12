import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^0jbps9v: ``RepetitionDetection/recoveriesPerAnswer`` counts the
/// consecutive stops of an answer with no progress between them. A tool call
/// after a recovery that gives a result, and that is not a repeat of an
/// earlier call of the answer, is progress and starts the count again.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``StagedReasoningModel``. No GPU is in the loop. The session's
/// counter is the ``CharacterTokenCounter``: one token per character.
@Suite("The recovery budget counts consecutive stops with no progress between them")
struct ConsecutiveRecoveryBudgetTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ConsecutiveRecoveryBudgetTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the failing test"

    /// The code of the first distinct tool call.
    private static let firstCode = "read(query, offset: 10)"

    /// The code of the second distinct tool call.
    private static let secondCode = "read(query, offset: 20)"

    /// The code of the third distinct tool call.
    private static let thirdCode = "read(query, offset: 30)"

    /// The code of the fourth distinct tool call.
    private static let fourthCode = "edit(query, line: 42)"

    /// A script whose reasoning reaches the default reasoning limit with new
    /// lines only, and that then waits until the session stops it.
    private static var reasoningStopScript: RepeatingReasoningScript {
        RepeatingReasoningScript.reasoningHeldAtLimit()
    }

    /// A script whose call writes no reasoning and asks for one
    /// ``CountingRunCodeTool`` call that runs `code`.
    ///
    /// - Parameter code: The code of the call.
    /// - Returns: The script.
    private static func toolCallScript(running code: String) -> RepeatingReasoningScript {
        RepeatingReasoningScript(reasoningLines: [], hold: .noHold, ending: .runCode(code))
    }

    /// Runs one streamed answer over a ``StagedReasoningSessionFixture`` with
    /// the default ``RepetitionDetection`` and one ``CountingRunCodeTool``.
    ///
    /// When the answer throws, this helper first closes the session and
    /// removes the temp directory of the fixture (rule T1). When it returns,
    /// the caller ends the fixture.
    ///
    /// - Parameter scripts: The script of each call, in call order.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runStagedAnswer(
        scripts: [RepeatingReasoningScript]
    ) async throws -> (fixture: StagedReasoningSessionFixture, events: [SessionEvent]) {
        let fixture = try await StagedReasoningSessionFixture.make(
            scripts: scripts, detection: RepetitionDetection(), tools: [CountingRunCodeTool(runs: RunCount())],
            tempDirPrefix: tempDirPrefix)
        let events = try await fixture.endingOnThrow {
            try await collect(fixture.session.streamEvents(to: prompt))
        }
        return (fixture, events)
    }

    @Test("stop, act, stop, act, stop, act, stop, act: each of the four reasoning stops recovers")
    func stopsWithProgressBetweenNeverRunOut() async throws {
        let codes = [Self.firstCode, Self.secondCode, Self.thirdCode, Self.fourthCode]
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: codes.flatMap { [Self.reasoningStopScript, Self.toolCallScript(running: $0)] })
        defer { await fixture.end() }

        #expect(events.reasoningStops.map(\.recovery) == [1, 1, 1, 1])
    }

    @Test("stops with no tool call between them end the answer after the recoveries of the budget")
    func stopsWithNoProgressRunOut() async throws {
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: Array(repeating: Self.reasoningStopScript, count: RepetitionDetection.defaultRecoveriesPerAnswer + 1))
        defer { await fixture.end() }

        #expect(events.reasoningStops.map(\.recovery) == [1, 2, nil])
    }

    @Test("a recovery followed by a tool call identical to an earlier one does not start the count again")
    func repeatedToolCallIsNoProgress() async throws {
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: [
                Self.reasoningStopScript, Self.toolCallScript(running: Self.firstCode),
                Self.reasoningStopScript, Self.toolCallScript(running: Self.firstCode),
                Self.reasoningStopScript,
            ])
        defer { await fixture.end() }

        #expect(events.reasoningStops.map(\.recovery) == [1, 1, 2])
    }

    @Test("a repeated-tool-call stop and reasoning stops share one consecutive count")
    func repetitionAndReasoningStopsShareTheCount() async throws {
        let repeatedCalls = Array(
            repeating: Self.toolCallScript(running: Self.firstCode),
            count: RepetitionDetection.defaultIdenticalToolCallLimit)
        let (fixture, events) = try await Self.runStagedAnswer(
            scripts: repeatedCalls + [
                Self.reasoningStopScript, Self.toolCallScript(running: Self.secondCode), Self.reasoningStopScript,
            ])
        defer { await fixture.end() }

        #expect(events.watchStops.map(\.kind) == [.repetition, .reasoning, .reasoning])
        #expect(events.watchStops.map(\.recovery) == [1, 2, 1])
    }
}
