import Evaluations
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// Loads ``CompactionContinuityEvalRealSubjectRunner`` at most once for the
/// real-model `@Test` below — declared at file scope for the same reason
/// `compactionEvalRealSubjectRunner` is: it must be referenceable from the
/// synchronously-evaluated `.evaluates(...)` trait argument.
///
/// The runner drives ``compactionContinuityFastTierSeeds`` under
/// ``compactionContinuityFastSummarization`` — the gated tier's own task set
/// and one-turn recency window, which the suite's doc comment below explains.
private let compactionContinuityEvalRealSubjectRunner = CompactionContinuityEvalRealSubjectRunner(
    tasks: compactionContinuityFastTierSeeds,
    instructions: compactionContinuityFastInstructions,
    summarization: compactionContinuityFastSummarization
)

/// The real-model evaluation itself: points at the FAST seed of every task
/// ``compactionContinuityFastTierIDs`` names, with the router's default
/// compaction prompt and the fast tier's synthetic budget, driving each
/// through a real, auto-compacting session.
private let compactionContinuityEvalRealEvaluation = CompactionContinuityEvaluation(
    budget: compactionContinuityFastBudget,
    tasks: compactionContinuityFastTierSeeds
) { steps, finalInstruction, prompt, budget in
    try await compactionContinuityEvalRealSubjectRunner.run(
        steps: steps, finalInstruction: finalInstruction, prompt: prompt, budget: budget)
}

/// The real-model continuity eval (tasks 4ce0a1k, ^k0d30s4 and ^mx4jqrn):
/// drives the fast seed of every task ``compactionContinuityFastTierIDs``
/// names through a real, auto-compacting session and asserts mean
/// `FoldOccurred`, `FactsSurvived`, and `AnswersCorrect` across those tasks
/// meet their measured floors.
///
/// ## What this tier proves
///
/// For every one of the four tasks the tier names: a real session vended with
/// a budget folds ITSELF inside a turn (no caller asks), the fold's summary is
/// written by a real model, and the final instruction is answered over the
/// folded transcript. `FoldOccurred` counts APPLIED folds only, so a green
/// run states that a real fold changed every task's transcript, and the two
/// fact floors state that planted facts traveled through the fold and back
/// out of a real answering turn at the small model's measured rates.
///
/// ## What it NO LONGER proves (tasks ^k0d30s4 and ^mx4jqrn)
///
/// Six of the ten hand-written tasks are not driven (task ^mx4jqrn). Ten
/// tasks under ``CompactionContinuityRealModel`` measured 219.1 seconds on
/// 2026-08-20 and 99.5 on 2026-08-21, which the two-minute budget does not
/// hold with margin, so the tier drives the four
/// ``compactionContinuityFastTierIDs`` names and states why each is there.
/// The six still have fast seeds, and the hermetic sizing proofs still hold
/// every one of them, so a later re-measurement can widen the list without
/// new fixtures.
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
/// a run inside it states its measurement. Measured on 2026-08-21 with
/// Qwen2.5-3B already in the Hugging Face cache, over the four tasks: 30.9
/// and 29.7 seconds of suite wall clock across two runs, against the
/// two-minute limit — the four tasks cost 6.1 to 8.6 seconds each and the
/// model loaded in 1.4. The bound the dearest task of the day's ten-task run
/// derives, 4 x 17.1 s plus 1.3 s, is 69.7 seconds, so the tier never reaches
/// its limit even when every task lands where the dearest landed. The 1B
/// model this suite drove before measured 26.2 to 41.4 seconds over ten tasks
/// on 2026-08-19.
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
        let foldOccurred = result.aggregateValue(.mean(of: CompactionContinuityMetric.foldOccurred))
        let factsSurvived = result.aggregateValue(.mean(of: CompactionContinuityMetric.factsSurvived))
        let answersCorrect = result.aggregateValue(.mean(of: CompactionContinuityMetric.answersCorrect))
        // Printed before the assertions, so a run that clears its floors still
        // states the shares it measured: the floors below are re-derived from
        // exactly these numbers, and a passing assertion prints nothing.
        print(
            "\(CompactionEvalProgressLog.linePrefix) continuity measured"
                + " tasks=\(compactionContinuityFastTierSeeds.count)"
                + " foldOccurred=\(foldOccurred) factsSurvived=\(factsSurvived) answersCorrect=\(answersCorrect)")
        // Every fast task is built so its one fold is APPLIED — the runner
        // counts no discarded fold — so this is the mechanical proof that a
        // real fold ran for this actual run, not merely an authoring-time
        // claim.
        #expect(foldOccurred == 1.0)
        #expect(factsSurvived >= compactionContinuityFastFactsSurvivedFloor)
        #expect(answersCorrect >= compactionContinuityFastAnswersCorrectFloor)
    }
}
