import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model this suite drives: the 4B that reasons and calls tools, which
/// `PropagationProbeIntegrationTests` and `RealToolTurnComparisonTests` also use
/// for a real tool turn.
private let passBoundaryModel: ModelRef = "mlx-community/Qwen3-4B-4bit"

/// Task ^8nqkten, over `MLXLanguageModel`: does one call of the MLX executor end
/// before the SDK runs the tool body that call emitted?
///
/// The ungated twin, `ExecutorPassBoundaryTests`, asks the same question of the
/// scripted model. The MLX executor sends its events in its own way
/// (`MLXLanguageModel.swift`, `emitToolCall` and the `perform` scope of the tool
/// path), so the answer must also hold here before a per-model queue holds one
/// place for one executor call.
@Suite(
    "Gated executor pass boundary over MLXLanguageModel (task ^8nqkten)",
    .serialized,
    .exclusiveRealModel
)
struct ExecutorPassBoundaryIntegrationTests {
    /// How long the tool body holds. Far longer than the gap between two
    /// events of one pass, so a pass kept open across the body shows.
    private static let toolHold = Duration.seconds(2)

    /// How long the slow consumer waits after each snapshot.
    ///
    /// The tool path of the MLX executor buffers its output and sends few
    /// events: the run of 2026-09-24 gave 4 snapshots for a whole tool turn.
    /// With so few snapshots, this test cannot show if a much slower consumer
    /// keeps the last pass open for its last send. It shows only that the pass
    /// that emits the tool call still ends before the tool body under a slow
    /// consumer. `ExecutorPassBoundaryTests` shows, over the scripted model,
    /// that no pass waits for the consumer.
    private static let slowConsumerPause = Duration.milliseconds(20)

    /// The instructions that make the model call the probe tool one time.
    private static let instructions = """
        You always call the `\(PassBoundaryProbeTool.toolName)` tool exactly once with the value \
        'alpha', then you answer with the tool's result in one short sentence.
        """

    /// The prompt of each turn.
    private static let prompt = "Look up alpha with the \(PassBoundaryProbeTool.toolName) tool."

    /// Argmax decoding and the shared reply ceiling of the gated suites.
    private static let turnOptions = GenerationOptions(
        samplingMode: .greedy, maximumResponseTokens: GatedRealModelBudget.responseTokenCeiling)

    /// Loads the model, and builds a session over the timed MLX model with the
    /// holding tool mounted.
    ///
    /// - Parameter log: The log the model and the tool record into.
    /// - Returns: The session, and the loaded container to evict at the end.
    /// - Throws: What the load throws.
    private static func makeSession(
        recordingInto log: PassBoundaryLog
    ) async throws -> (session: LanguageModelSession, loaded: RealModelContainer) {
        let loaded = try await RealModelContainer.load(ref: passBoundaryModel)
        let model = PassBoundaryProbeModel(wrapping: loaded.container.model, log: log)
        let session = LanguageModelSession(
            model: model, tools: [PassBoundaryProbeTool(log: log, holdDuration: toolHold)],
            instructions: instructions)
        return (session, loaded)
    }

    @Test("respond: the MLX pass that emits a tool call ends before the SDK runs the tool body")
    func respondPassEndsBeforeToolBody() async throws {
        let log = PassBoundaryLog()
        let (session, loaded) = try await Self.makeSession(recordingInto: log)

        _ = try await session.respond(to: Self.prompt, options: Self.turnOptions)

        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        try PassBoundaryExpectations.expectNextPassStartsAfterToolBody(in: log)
        await loaded.container.model.evict()
    }

    @Test("stream: the MLX pass that emits a tool call ends before the SDK runs the tool body")
    func streamPassEndsBeforeToolBody() async throws {
        let log = PassBoundaryLog()
        let (session, loaded) = try await Self.makeSession(recordingInto: log)

        let snapshotCount = try await PassBoundaryExpectations.consumeSlowly(
            session.streamResponse(to: Self.prompt, options: Self.turnOptions), pausingAfterEach: .zero)

        #expect(snapshotCount > 0)
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        try PassBoundaryExpectations.expectNextPassStartsAfterToolBody(in: log)
        await loaded.container.model.evict()
    }

    @Test("stream: with a slow consumer, the MLX pass still ends before the tool body")
    func slowStreamConsumerStillEndsPassBeforeToolBody() async throws {
        let log = PassBoundaryLog()
        let (session, loaded) = try await Self.makeSession(recordingInto: log)

        let consumeStarted = ContinuousClock.now
        let snapshotCount = try await PassBoundaryExpectations.consumeSlowly(
            session.streamResponse(to: Self.prompt, options: Self.turnOptions),
            pausingAfterEach: Self.slowConsumerPause)
        let consumeEnded = ContinuousClock.now

        #expect(snapshotCount > 0)
        try PassBoundaryExpectations.expectFirstPassEndsBeforeItsToolBody(in: log)
        let lastPassEnd = try #require(log.recorded.last { $0.boundary == .executorExited })
        // Printed, not asserted: the measurement the card asks for. A pass that
        // waited for the consumer ends near the consumer's end; a pass that
        // does not wait ends long before it. The gated run's record for the
        // card: a reader copies this line. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print(
            "[slowStreamConsumer] snapshots=\(snapshotCount) passDurations=\(log.passDurations) "
                + "consumeTotal=\(consumeStarted.duration(to: consumeEnded)) "
                + "consumerLagAfterLastPass=\(lastPassEnd.instant.duration(to: consumeEnded))"
        )
        await loaded.container.model.evict()
    }
}
