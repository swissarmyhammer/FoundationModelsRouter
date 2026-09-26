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
/// brackets its body, which holds for ``toolHold``, with two more. The gated
/// twin over `MLXLanguageModel` is `ExecutorPassBoundaryIntegrationTests`.
@Suite("Executor pass boundary: a pass ends before the SDK runs its tool body (task ^8nqkten)")
struct ExecutorPassBoundaryTests {
    /// How long the tool body holds. Long enough that a pass kept open across
    /// the body cannot hide inside scheduling noise.
    private static let toolHold = Duration.seconds(1)

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

    /// A session over the timed scripted model, with the holding tool mounted.
    ///
    /// - Parameter log: The log the model and the tool record into.
    /// - Returns: A fresh session.
    private static func makeSession(recordingInto log: PassBoundaryLog) -> LanguageModelSession {
        let model = PassBoundaryProbeModel(
            wrapping: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()), log: log)
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

    @Test("stream: a consumer slower than generation keeps no pass open", .timeLimit(.minutes(1)))
    func slowStreamConsumerKeepsNoPassOpen() async throws {
        let log = PassBoundaryLog()

        let snapshots = Self.makeSession(recordingInto: log).streamResponse(to: ScriptedToolFixture.prompt)
        let snapshotCount = try await Self.consumeAfterEachOpenPassEnds(snapshots, log: log)

        #expect(snapshotCount > 0)
        #expect(log.passDurations.count == Self.expectedPassCount, "\(log.boundaries)")
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
    }

    /// Reads every element of `stream`, and after each one waits until every
    /// pass that `log` saw start has ended: a consumer slower than any pass.
    ///
    /// The wait is on the pass boundaries, not on a clock (task ^v4zh807). A
    /// pass that holds its end until the consumer reads the next element
    /// never ends, so the wait never ends, and the `.timeLimit` of the test
    /// fails it. A pass that a loaded machine makes slow only makes the wait
    /// longer. The earlier form of this test compared each pass with a
    /// 300 ms pause of the consumer, and a loaded machine made a pass longer
    /// than that with no consumer involved.
    ///
    /// - Parameters:
    ///   - stream: The stream to read.
    ///   - log: The log the executor records each pass into.
    /// - Returns: How many elements the stream gave.
    /// - Throws: What the stream throws, or ``ConditionNeverHeld`` when the
    ///   `.timeLimit` of the test ended a wait.
    private static func consumeAfterEachOpenPassEnds<Stream: AsyncSequence>(
        _ stream: Stream, log: PassBoundaryLog
    ) async throws -> Int {
        var elementCount = 0
        for try await _ in stream {
            elementCount += 1
            try await AwaitedCondition.wait(until: { hasNoOpenPass(in: log) })
        }
        return elementCount
    }

    /// Whether every pass that `log` saw start has also ended.
    ///
    /// - Parameter log: The log the executor records each pass into.
    /// - Returns: Whether the log holds as many pass ends as pass starts.
    private static func hasNoOpenPass(in log: PassBoundaryLog) -> Bool {
        let boundaries = log.boundaries
        let starts = boundaries.filter { $0 == .executorEntered }.count
        let ends = boundaries.filter { $0 == .executorExited }.count
        return starts == ends
    }
}
