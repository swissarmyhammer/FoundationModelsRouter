import Evaluations
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// Loads ``CompactionContinuityEvalRealSubjectRunner`` at most once for the
/// real-model `@Test` below — declared at file scope for the same reason
/// `compactionEvalRealSubjectRunner` is: it must be referenceable from the
/// synchronously-evaluated `.evaluates(...)` trait argument.
///
/// The runner drives ``compactionContinuityFastSeeds`` under
/// ``compactionContinuityFastSummarization`` — the fast tier's own task set
/// and one-turn recency window, which the suite's doc comment below explains.
private let compactionContinuityEvalRealSubjectRunner = CompactionContinuityEvalRealSubjectRunner(
    tasks: compactionContinuityFastSeeds,
    instructions: compactionContinuityFastInstructions,
    summarization: compactionContinuityFastSummarization
)

/// The real-model evaluation itself: points at every hand-written task's FAST
/// seed with the router's default compaction prompt and the fast tier's
/// synthetic budget, driving each through a real, auto-compacting session.
private let compactionContinuityEvalRealEvaluation = CompactionContinuityEvaluation(
    budget: compactionContinuityFastBudget,
    tasks: compactionContinuityFastSeeds
) { steps, finalInstruction, prompt, budget in
    try await compactionContinuityEvalRealSubjectRunner.run(
        steps: steps, finalInstruction: finalInstruction, prompt: prompt, budget: budget)
}

/// The real-model continuity eval (tasks 4ce0a1k and ^k0d30s4): drives every
/// hand-written task's fast seed through a real, auto-compacting session and
/// asserts mean `FoldOccurred`, `FactsSurvived`, and `AnswersCorrect` across
/// the whole dataset meet their measured floors.
///
/// ## What this tier proves
///
/// For every one of the ten hand-written tasks: a real session vended with a
/// budget folds ITSELF inside a turn (no caller asks), the fold's summary is
/// written by a real model, and the final instruction is answered over the
/// folded transcript. `FoldOccurred` counts APPLIED folds only, so a green
/// run states that a real fold changed every task's transcript, and the two
/// fact floors state that planted facts traveled through the fold and back
/// out of a real answering turn at the small model's measured rates.
///
/// ## What it NO LONGER proves (task ^k0d30s4)
///
/// This tier drove thirteen real 30B generations per task before, to push a
/// live session past ``compactionContinuityDefaultBudget``'s 1638-token
/// trigger, and it held `AnswersCorrect` to 0.8. One sample of ten then used
/// the whole 1200-second limit, against a budget of two minutes per test.
/// The fast seeds replace the filler with ``compactionContinuityFastBudget``'s
/// synthetic trigger, so what is no longer proven is:
///
/// - **The 30B model's continuity, and its 0.8 whole-task bar.** The floors
///   here are the SMALL model's measured baselines minus one task of margin —
///   see ``compactionContinuityFastAnswersCorrectFloor`` for the measurement
///   and for why the 0.8 bar cannot be held against this subject. The bars
///   are regression floors: a compaction-prompt change that loses facts from
///   the summaries crashes them.
/// - **Continuity across MANY folds of a long conversation.** Each fast task
///   folds once, at the final turn, over a span that holds both facts. A
///   thirteen-step task could fold several times, wherever its growth crossed
///   the trigger.
/// - **The real trigger's placement.** The synthetic trigger proves the
///   wiring fires; whether 0.80 of a real window is the right moment to fold
///   is not measured here, exactly as `AutoCompactionTriggerIntegrationTests`
///   records for itself.
///
/// The TARGET is what selects this suite, and it carries no `.enabled(if:)`
/// of its own — see ``GatedEvalSerialGate`` for the commands that ask for this
/// target and the command that leaves it out.
///
/// `.exclusiveResidentModel(of:)` holds this suite's real model exclusive
/// against the other real-model eval suites, evicts it when the suite ends,
/// and prints the suite's own wall clock, so a run past
/// ``gatedEvalSuiteTimeLimitMinutes`` fails rather than merely being slow and
/// a run inside it states its measurement. Measured on 2026-08-19 with the
/// model already in the Hugging Face cache: 26.2 to 41.4 seconds of wall
/// clock across the tuning runs, against the two-minute limit.
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
        // Every fast task is built so its one fold is APPLIED — the runner
        // counts no discarded fold — so this is the mechanical proof that a
        // real fold ran for this actual run, not merely an authoring-time
        // claim.
        #expect(result.aggregateValue(.mean(of: CompactionContinuityMetric.foldOccurred)) == 1.0)
        #expect(
            result.aggregateValue(.mean(of: CompactionContinuityMetric.factsSurvived))
                >= compactionContinuityFastFactsSurvivedFloor)
        #expect(
            result.aggregateValue(.mean(of: CompactionContinuityMetric.answersCorrect))
                >= compactionContinuityFastAnswersCorrectFloor)
    }
}
