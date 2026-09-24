import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^8nqkten, over the scripted model: does one call of the executor end
/// before the SDK runs the tool body that call emitted?
///
/// A per-model generation queue holds one place for one executor call. That is
/// safe only when the call is not open while the tool body runs: a tool that
/// waits for a child turn on the same model would otherwise wait for a place
/// its own turn holds. ``PassBoundaryProbeModel`` brackets each executor call
/// of ``ScriptedToolCallingModel`` with two events, and ``PassBoundaryProbeTool``
/// brackets its body, which holds for ``toolHold``, with two more. The gated
/// twin over `MLXLanguageModel` is `ExecutorPassBoundaryIntegrationTests`.
@Suite("Executor pass boundary: a pass ends before the SDK runs its tool body (task ^8nqkten)")
struct ExecutorPassBoundaryTests {
    /// How long the tool body holds. Long enough that a pass kept open across
    /// the body cannot hide inside scheduling noise.
    private static let toolHold = Duration.seconds(1)

    /// How long the slow consumer waits after each snapshot. Far longer than a
    /// scripted pass takes, so a pass that waits for the consumer runs at least
    /// this long.
    private static let slowConsumerPause = Duration.milliseconds(300)

    /// How many executor calls the turn makes: the pass that emits the tool
    /// call, and the pass that answers after the tool output.
    private static let expectedPassCount = 2

    /// One round with one call of the probe tool, with narration before the
    /// call, so the tool pass sends two events into the channel.
    private static let script = ScriptedTurnScript(
        rounds: [
            [
                ScriptedToolCall(
                    id: "probe-call-0", toolName: PassBoundaryProbeTool.toolName, argument: .literal("alpha"))
            ]
        ],
        narration: "Let me look that up."
    )

    /// A session over the timed scripted model, with the holding tool mounted.
    ///
    /// - Parameter log: The log the model and the tool record into.
    /// - Returns: A fresh session.
    private static func makeSession(recordingInto log: PassBoundaryLog) -> LanguageModelSession {
        let model = PassBoundaryProbeModel(
            wrapping: ScriptedToolCallingModel(script: script, log: ScriptedTurnLog()), log: log)
        return LanguageModelSession(
            model: model, tools: [PassBoundaryProbeTool(log: log, holdDuration: toolHold)])
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
        let snapshotCount = try await PassBoundaryExpectations.consumeSlowly(
            snapshots, pausingAfterEach: .zero)

        #expect(snapshotCount > 0)
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        try PassBoundaryExpectations.expectNextPassStartsAfterToolBody(in: log)
    }

    @Test("stream: a consumer slower than generation keeps no pass open")
    func slowStreamConsumerKeepsNoPassOpen() async throws {
        let log = PassBoundaryLog()

        let snapshots = Self.makeSession(recordingInto: log).streamResponse(to: ScriptedToolFixture.prompt)
        let snapshotCount = try await PassBoundaryExpectations.consumeSlowly(
            snapshots, pausingAfterEach: Self.slowConsumerPause)

        #expect(snapshotCount > 0)
        let passDurations = log.passDurations
        #expect(passDurations.count == Self.expectedPassCount, "\(log.boundaries)")
        #expect(
            passDurations.allSatisfy { $0 < Self.slowConsumerPause },
            "a pass waited for the consumer: \(passDurations)")
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
    }
}
