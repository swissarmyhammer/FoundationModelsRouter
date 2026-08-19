import Evaluations
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// Loads ``CompactionContinuityEvalRealSubjectRunner`` at most once for the
/// real-model `@Test` below — declared at file scope for the same reason
/// `compactionEvalRealSubjectRunner` is: it must be referenceable from the
/// synchronously-evaluated `.evaluates(...)` trait argument.
private let compactionContinuityEvalRealSubjectRunner = CompactionContinuityEvalRealSubjectRunner()

/// The real-model evaluation itself: points at every hand-written multi-step
/// task with the router's default compaction prompt, driving each through a
/// real, auto-compacting session.
private let compactionContinuityEvalRealEvaluation = CompactionContinuityEvaluation { steps, finalInstruction, prompt, budget in
    try await compactionContinuityEvalRealSubjectRunner.run(
        steps: steps, finalInstruction: finalInstruction, prompt: prompt, budget: budget)
}

/// The real-model eval (task 4ce0a1k): drives every hand-written multi-step
/// task through a real, auto-compacting session and asserts mean
/// `AnswersCorrect` and `FoldOccurred` across the whole dataset meet their
/// thresholds.
///
/// The TARGET is what selects this suite, and it carries no `.enabled(if:)` of
/// its own — see ``GatedEvalSerialGate`` for the commands that ask for this
/// target and the command that leaves it out.
///
/// This suite was long described here as blocked by an MLX `default.metallib`
/// load failure that no real-model suite in this repository could get past.
/// That was wrong: the failure was a resource-colocation bug in `swift test`'s
/// binary layout, which ``MetalLibraryTestBootstrap`` now fixes from inside
/// ``GatedEvalResidencyTrait``, this suite's own trait.
///
/// ``GatedEvalResidencyTrait`` holds this suite's real model exclusive against
/// the other real-model eval suites and evicts it when the suite ends, and
/// ``gatedEvalSuiteTimeLimitMinutes`` bounds a hung real-model load — see
/// ``GatedEvalSerialGate`` for why the target needs both.
@Suite(
    .exclusiveResidentModel(of: compactionContinuityEvalRealSubjectRunner),
    .timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))
)
struct CompactionContinuityEvaluationIntegrationTests {
    @Test(
        "Compaction preserves session continuity across a multi-step task",
        .evaluates(
            compactionContinuityEvalRealEvaluation,
            info: ["promptName": CompactionPrompt.default.name]
        )
    )
    func evaluateContinuity() async throws {
        let result = EvaluationContext.current.result
        // Every hand-written task is sized so at least one live fold is
        // forced somewhere in the middle — this is the mechanical proof that
        // held for this actual run, not merely an authoring-time claim.
        #expect(result.aggregateValue(.mean(of: CompactionContinuityMetric.foldOccurred)) == 1.0)
        #expect(result.aggregateValue(.mean(of: CompactionContinuityMetric.answersCorrect)) >= 0.8)
    }
}
