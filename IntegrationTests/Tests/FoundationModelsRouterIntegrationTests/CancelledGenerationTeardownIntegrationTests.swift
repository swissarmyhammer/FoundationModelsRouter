import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model this suite cancels mid-generation: the same 1B model the
/// compaction smoke suite drives, small enough that the whole suite stays
/// inside the two-minute integration budget.
private let cancellationSmokeModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The response-token ceiling of the generation this suite cancels.
///
/// Sized so the generation is still decoding on the GPU when the cancel
/// lands at ``cancellationDelaySeconds``: at the 1B model's measured decode
/// rate this many tokens run well past that point, and — should cancellation
/// fail to propagate at all — a full uncancelled run still ends inside the
/// suite's ``integrationTestBudgetMinutes`` limit rather than hanging it.
private let cancelledGenerationMaxTokens = 2048

/// How long the suite lets the doomed generation run before it cancels it.
///
/// Long enough that the short prompt's prefill is over and token decode is in
/// flight on the GPU — the state the gated eval was in when its time limit
/// fired — and short enough to keep the suite fast.
private let cancellationDelaySeconds = 2

/// Regression coverage for task `^bkdm97c`: a gated eval cancelled by its
/// Swift Testing time limit aborted the whole process on a Metal assertion —
/// signal 6 out of `_MTLCommandBuffer addCompletedHandler:`, "Completed
/// handler provided after commit call".
///
/// The gated run's timeline was: the time limit cancels the test task while a
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
/// 5.7, then 5.7 seconds, against the shared ``integrationTestBudgetMinutes``
/// this suite now states as its limit; see it for the whole run table.
@Suite(
    "Gated real-model coverage: cancellation mid-generation does not abort the process (task bkdm97c)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct CancelledGenerationTeardownIntegrationTests {
    @Test("a generation cancelled mid-decode unwinds as CancellationError, and the model evicts and reloads cleanly")
    func aCancelledGenerationUnwindsAndTheProcessSurvives() async throws {
        let container = try await RealModelContainer.load(
            ref: cancellationSmokeModel,
            samplingMode: .greedy
        )
        let backend = container.makeSession(
            instructions: "You are a terse, literal assistant.")

        // A prompt the model cannot finish early: it decodes until the token
        // ceiling, so the cancel below always lands mid-decode.
        let doomed = Task {
            try await backend.respond(
                to: "Count upward from 1, one number per line, without stopping.",
                maxTokens: cancelledGenerationMaxTokens
            )
        }
        try await Task.sleep(for: .seconds(cancellationDelaySeconds))
        doomed.cancel()

        // The cancelled call must END, and it must end by observing the
        // cancellation. A `.success` here means cancellation never reached
        // the generation at all — the card's open question 2 — and is a
        // failure of its own, distinct from the signal-6 abort.
        let outcome = await doomed.result
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
        await container.model.evict()

        // And the next suite loads the model again and generates. The process
        // surviving a fresh generation proves the cancelled one left no
        // half-committed command buffer behind.
        let reloaded = try await RealModelContainer.load(
            ref: cancellationSmokeModel,
            samplingMode: .greedy
        )
        let reply = try await reloaded.makeSession(
            instructions: "You are a terse, literal assistant."
        ).respond(
            to: "Say hi in one word.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(!reply.isEmpty)
        await reloaded.model.evict()
    }
}
