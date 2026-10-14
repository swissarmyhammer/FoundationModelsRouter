import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^8nqkten, over the scripted model: does one call of the executor end
/// before the SDK runs the tool body that call emitted?
///
/// A per-model generation queue holds one place for one executor call. That is
/// safe only when the call is not open while the tool body runs: a tool that
/// waits for a child answer on the same model would otherwise wait for a place
/// its own submission holds. ``PassBoundaryProbeModel`` brackets each executor call
/// of ``ScriptedToolCallingModel`` with two events, and ``PassBoundaryProbeTool``
/// brackets its body with two more. The checks read the order of the events,
/// not a clock, so the tool body needs no hold. The gated twin over
/// `MLXLanguageModel` is `ExecutorPassBoundaryIntegrationTests`.
@Suite("Executor pass boundary: a pass ends before the SDK runs its tool body (task ^8nqkten)")
struct ExecutorPassBoundaryTests {
    /// How many executor calls the submission makes: the pass that emits the tool
    /// call, and the pass that answers after the tool output.
    private static let expectedPassCount = 2

    /// One round with one call of the probe tool, with narration before the
    /// call, so the tool pass sends two events into the channel.
    private static let script = ScriptedAnswerScript(
        rounds: [
            [
                ScriptedToolCall(
                    id: "probe-call-0", toolName: PassBoundaryProbeTool.toolName, argument: .literal("alpha"))
            ]
        ],
        narration: "Let me look that up."
    )

    /// A session over the timed scripted model, with the probe tool mounted.
    ///
    /// - Parameter log: The log the model and the tool record into.
    /// - Returns: A fresh session.
    private static func makeSession(recordingInto log: PassBoundaryLog) -> LanguageModelSession {
        let model = PassBoundaryProbeModel(
            wrapping: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()), log: log)
        return LanguageModelSession(model: model, tools: [PassBoundaryProbeTool(log: log)])
    }

    @Test("respond: the pass that emits a tool call ends before the SDK runs the tool body")
    func respondPassEndsBeforeToolBody() async throws {
        let log = PassBoundaryLog()

        let response = try await Self.makeSession(recordingInto: log).respond(to: ScriptedToolFixture.prompt)

        #expect(response.content.contains("probe found alpha"))
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        try PassBoundaryExpectations.expectNextPassStartsAfterToolBody(in: log)
    }

    @Test("stream: the pass that emits a tool call ends before the SDK runs the tool body")
    func streamPassEndsBeforeToolBody() async throws {
        let log = PassBoundaryLog()

        let snapshots = Self.makeSession(recordingInto: log).streamResponse(to: ScriptedToolFixture.prompt)
        let snapshotCount = try await PassBoundaryExpectations.consume(snapshots)

        #expect(snapshotCount > 0)
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        try PassBoundaryExpectations.expectNextPassStartsAfterToolBody(in: log)
    }

    /// The earlier form of this test compared each pass with a 300 ms pause
    /// of the consumer, and a loaded machine made a pass longer than that with
    /// no consumer involved (task ^v4zh807). Now the consumer waits for the
    /// pass boundaries after each element, so no clock decides the result.
    @Test("stream: a consumer slower than generation keeps no pass open")
    func slowStreamConsumerKeepsNoPassOpen() async throws {
        let log = PassBoundaryLog()

        let snapshots = Self.makeSession(recordingInto: log).streamResponse(to: ScriptedToolFixture.prompt)
        let snapshotCount = try await PassBoundaryExpectations.consumeAfterEachOpenPassEnds(snapshots, log: log)

        #expect(snapshotCount > 0)
        #expect(log.passDurations.count == Self.expectedPassCount, "\(log.boundaries)")
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
    }
}
