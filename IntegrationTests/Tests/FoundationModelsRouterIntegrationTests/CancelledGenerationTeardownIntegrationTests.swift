import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport
@testable import MLXFoundationModels

/// The model this suite cancels mid-generation: the same 1B model the
/// compaction smoke suite drives, small enough to keep the whole suite fast.
private let cancellationSmokeModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The response-token ceiling of the generation this suite cancels.
///
/// The suite cancels the generation at the first text that the executor
/// decodes. Thus the prefill is over and the decode is on the GPU. This many
/// tokens give a decode that continues long after that first text. If the
/// cancel does not reach the generation, a full run still stops at this
/// ceiling.
private let cancelledGenerationMaxTokens = 2048

/// Regression coverage for task `^bkdm97c`: a gated eval whose test task was
/// cancelled mid-generation aborted the whole process on a Metal assertion —
/// signal 6 out of `_MTLCommandBuffer addCompletedHandler:`, "Completed
/// handler provided after commit call". A caller that stops a run cancels the
/// test task in the same way.
///
/// The gated run's timeline was: a cancellation reaches the test task while a
/// generation is on the GPU, the eval unwinds and prints its report, the
/// residency trait evicts the model, and the process dies. This suite
/// compresses that timeline onto the cheap 1B model: start a generation,
/// cancel it mid-decode, evict the model, then load and generate again. The
/// suite passing means the process survived every step; the defect
/// reproducing means signal 6, which no assertion can observe — the abort
/// itself is the red result.
///
/// The TARGET is what selects this suite, and no environment variable is
/// read — see `GatedSuiteSerialGate` for the commands that ask for this
/// target and the command that leaves it out.
///
/// The three runs of 2026-08-20 measured this suite's one test at 5.8, then
/// 5.7, then 5.7 seconds. The suite has no time limit. A run ends when it
/// ends, or when the caller stops it.
@Suite(
    "Gated real-model coverage: cancellation mid-generation does not abort the process (task bkdm97c)",
    .serialized,
    .exclusiveRealModel
)
struct CancelledGenerationTeardownIntegrationTests {
    /// Starts a generation on `backend` that cannot finish early, cancels it
    /// mid-decode, and waits for it to end.
    ///
    /// The prompt asks the model to count without stopping, so it decodes
    /// until the token ceiling. The cancel comes at the first text that the
    /// MLX executor sends into its channel. That text is the first event of
    /// the decode, so the cancel always comes after the prefill and in the
    /// decode.
    ///
    /// The executor shows each text to the test-only task-local observer
    /// `MLXLanguageModel.Executor.generationObserver` before it sends the
    /// text. The generation task inherits the observer, and the SDK runs the
    /// executor with the task-local values of that task.
    ///
    /// The end of the generation finishes the stream of texts. A generation
    /// that sends no text then also ends the wait. The cancel that follows has
    /// no effect, and the test records the `.success` outcome as an issue.
    ///
    /// - Parameter backend: The backend to generate on.
    /// - Returns: How the cancelled generation ended.
    private static func runCancelledGeneration(
        on backend: any LanguageModelSessionBackend
    ) async -> Result<String, any Error> {
        let (decodedTexts, decodedText) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let doomed = MLXLanguageModel.Executor.$generationObserver.withValue({ event in
            if case .appendText = event {
                decodedText.yield()
            }
        }) {
            Task {
                defer { decodedText.finish() }
                return try await backend.respond(
                    to: "Count upward from 1, one number per line, without stopping.",
                    maxTokens: cancelledGenerationMaxTokens
                )
            }
        }
        var firstDecodedText = decodedTexts.makeAsyncIterator()
        _ = await firstDecodedText.next()
        doomed.cancel()
        return await doomed.result
    }

    @Test("a generation cancelled mid-decode unwinds as CancellationError, and the model evicts and reloads cleanly")
    func aCancelledGenerationUnwindsAndTheProcessSurvives() async throws {
        let loaded = try await RealModelContainer.load(
            ref: cancellationSmokeModel,
            samplingMode: .greedy
        )
        let backend = loaded.container.makeSession(
            instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)

        // The cancelled call must END, and it must end by observing the
        // cancellation. A `.success` here means cancellation never reached
        // the generation at all — the card's open question 2 — and is a
        // failure of its own, distinct from the signal-6 abort.
        let outcome = await Self.runCancelledGeneration(on: backend)
        switch outcome {
        case .success(let text):
            Issue.record(
                """
                the cancelled generation ran to completion instead of \
                observing its cancellation (\(text.count) characters)
                """)
        case .failure(let error):
            #expect(
                error is CancellationError,
                "the cancelled generation must unwind as CancellationError, got \(error)")
        }

        // The gated timeline continues: the residency trait evicts the model
        // after the cancelled run. The abort under investigation fired in
        // this window — after the report, around teardown of the cancelled
        // generation's GPU work.
        await loaded.container.model.evict()

        // And the next suite loads the model again and generates. The process
        // surviving a fresh generation proves the cancelled one left no
        // half-committed command buffer behind.
        let reloaded = try await RealModelContainer.load(
            ref: cancellationSmokeModel,
            samplingMode: .greedy
        )
        defer { await reloaded.container.model.evict() }
        let reply = try await reloaded.container.makeSession(
            instructions: "You are a terse, literal assistant.", samplingMode: reloaded.samplingMode
        ).respond(
            to: "Say hi in one word.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(!reply.isEmpty)
    }

    /// Task ^3anq1yz: the MLX executor sends its one usage update only after
    /// a call completes. A cancelled call ends before that update, so the
    /// usage of the backend does not move: no fed tokens and no generated
    /// tokens. A watch stop of the session cancels a call in this way, and
    /// the session counts the tokens of the stopped call itself
    /// (``RoutedSessionActor/measureWatchStop(_:rebuilt:render:)``).
    @Test("a generation cancelled mid-decode reports no fed tokens and no generated tokens")
    func aCancelledGenerationReportsNoUsage() async throws {
        let loaded = try await RealModelContainer.load(
            ref: cancellationSmokeModel,
            samplingMode: .greedy
        )
        defer { await loaded.container.model.evict() }
        let backend = loaded.container.makeSession(
            instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)
        let usageBefore = try #require(backend.usageTokenCounts())

        let outcome = await Self.runCancelledGeneration(on: backend)

        #expect(throws: CancellationError.self) { try outcome.get() }
        let usageAfter = try #require(backend.usageTokenCounts())
        #expect(usageAfter.input - usageBefore.input == 0)
        #expect(usageAfter.output - usageBefore.output == 0)
    }
}
