import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^dvkxz7n: a tool call that fails does not end the submission.
///
/// Apple's `LanguageModelSession` cancels the other calls of a submission when
/// one call throws, and then it ends the submission. The mount decorators
/// therefore give an ordinary failure to the model as a tool result, and they
/// throw only for a true cancellation: a cancel of the task of the call. A
/// `CancellationError` while the task of the call is not cancelled is an
/// ordinary failure. This suite drives real answers over the scripted model
/// and holds the three conditions of the card: the good calls beside a failed
/// call complete, the model reads the failure and can call again, and a
/// cancellation still stops the submission.
@Suite("A failed tool call is a tool result, and a cancellation still stops the submission")
struct ToolCallFailureAnswerTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ToolCallFailureAnswerTests"

    /// The step names the scripted calls use, named once so a script and its
    /// assertions cannot drift apart.
    private enum Step {
        /// The step the failing call names.
        static let failing = "BOOM"

        /// The steps the good calls beside the failing call name.
        static let good = ["ONE", "TWO", "THREE"]
    }

    /// The position of the failed call's output in the transcript — where the
    /// follow-up call reads its argument from.
    private static let failureOutputIndex = 0

    /// The text the model reads for the failing call: the error the tool body
    /// threw, as the mount describes it.
    private static let failureText = String(
        describing: ThrowingMarkerTool.CallFailure(step: Step.failing))

    /// Builds one scripted call on `toolName` with the argument `argument`.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool to call.
    ///   - argument: How the call's `value` argument is produced.
    /// - Returns: The scripted call.
    private static func call(
        on toolName: String, with argument: ScriptedCallArgument
    ) -> ScriptedToolCall {
        ScriptedToolCall(id: "\(toolName)-\(argument)", toolName: toolName, argument: argument)
    }

    /// Whether `error` is a true cancellation: a `CancellationError`, or the
    /// SDK's `ToolCallError` around one.
    ///
    /// - Parameter error: The error the answer threw.
    /// - Returns: `true` when the answer ended as cancelled.
    private static func isCancellation(_ error: any Error) -> Bool {
        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            return toolCallError.underlyingError is CancellationError
        }
        return error is CancellationError
    }

    /// Waits until `tool` sent ``CancellingMarkerTool/entered``, or until
    /// `answering` ended (rule T1), and then requires that the call of `tool`
    /// ran.
    ///
    /// The answer ends only after the cancel of the test when the call runs,
    /// so in a test that passes the answer does not end first. An answer that
    /// ends with no call of the tool then fails the test here.
    ///
    /// - Parameters:
    ///   - tool: The tool whose call the test stops.
    ///   - answering: The task of the answer.
    /// - Throws: The error of `#require` when the answer ended before the call
    ///   of `tool` ran, or ``ConditionNeverHeld`` when the test was cancelled
    ///   first.
    private static func waitForEntry(
        of tool: CancellingMarkerTool, orEndOf answering: Task<String, any Error>
    ) async throws {
        try await RecordedWaitResult.wait(for: { try await tool.entered.wait() }, endingOnEndOf: answering)
        try #require(tool.calledSteps == [Step.failing])
    }

    @Test("an answer with one failed call and three good calls completes the three and answers", arguments: FailingToolRow.everyMountRoute)
    func goodCallsBesideAFailedCallComplete(_ row: FailingToolRow) async throws {
        let failingTool = row.makeTool()
        let markerTool = MarkerEmittingTool()
        let round =
            [Self.call(on: row.toolName, with: .literal(Step.failing))]
            + Step.good.map { Self.call(on: MarkerEmittingTool.toolName, with: .literal($0)) }
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [round]),
            mounting: [failingTool, markerTool],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        #expect(failingTool.calledSteps == [Step.failing])
        #expect(markerTool.calledSteps.sorted() == Step.good.sorted())
        let expectedOutputs = [Self.failureText] + Step.good.map(ScriptedToolFixture.marker(for:))
        #expect(fixture.log.deliveredToolOutputs.sorted() == expectedOutputs.sorted())
        #expect(answer == ScriptedToolFixture.answer(fromToolOutputs: fixture.log.deliveredToolOutputs))
    }

    @Test("the model reads the failure as a tool result and makes another call", arguments: FailingToolRow.everyMountRoute)
    func modelReadsTheFailureAndCallsAgain(_ row: FailingToolRow) async throws {
        let failingTool = row.makeTool()
        let markerTool = MarkerEmittingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [Self.call(on: row.toolName, with: .literal(Step.failing))],
                [
                    Self.call(
                        on: MarkerEmittingTool.toolName,
                        with: .priorToolOutput(index: Self.failureOutputIndex))
                ],
            ]),
            mounting: [failingTool, markerTool],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let expectedOutputs = [Self.failureText, ScriptedToolFixture.marker(for: Self.failureText)]
        #expect(failingTool.calledSteps == [Step.failing])
        #expect(markerTool.calledSteps == [Self.failureText])
        #expect(fixture.log.deliveredToolOutputs == expectedOutputs)
        #expect(answer == ScriptedToolFixture.answer(fromToolOutputs: expectedOutputs))
    }

    @Test("a tool call that ends as cancelled still stops the submission")
    func cancellationStillStopsTheSubmission() async throws {
        let cancellingTool = CancellingMarkerTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [Self.call(on: CancellingMarkerTool.toolName, with: .literal(Step.failing))]
            ]),
            mounting: [cancellingTool],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answering = Task { try await fixture.session.respond(to: ScriptedToolFixture.prompt) }

        // The stop comes when the tool call runs, as a stop of a user does.
        // It cancels the model call, so the task of the tool call is
        // cancelled, and the tool ends at that cancel.
        try await Self.waitForEntry(of: cancellingTool, orEndOf: answering)
        fixture.session.cancelAll()
        let error = await #expect(throws: (any Error).self) {
            _ = try await answering.value
        }
        // The stop sends the end of the answer before the stopped submission
        // ends. The checks of the passes need that end, so the test waits
        // for the pump.
        #expect(await fixture.session.pumpEnds())

        #expect(error.map(Self.isCancellation) == true, "the answer ended with \(String(describing: error))")
        // Only the round that asked for the call generated: the answering
        // generation never ran.
        #expect(fixture.log.generationPassCount == 1)
        #expect(fixture.log.deliveredToolOutputs.isEmpty)
    }

    @Test("a tool that throws CancellationError while its call is not cancelled gives the model a failure tool result")
    func cancellationErrorOfOtherWorkIsAToolResult() async throws {
        let failingTool = ThrowingMarkerTool(failingWith: { _ in CancellationError() })
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [Self.call(on: ThrowingMarkerTool.toolName, with: .literal(Step.failing))]
            ]),
            mounting: [failingTool],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let expectedOutputs = [String(describing: CancellationError())]
        #expect(failingTool.calledSteps == [Step.failing])
        #expect(fixture.log.deliveredToolOutputs == expectedOutputs)
        #expect(answer == ScriptedToolFixture.answer(fromToolOutputs: expectedOutputs))
    }
}
