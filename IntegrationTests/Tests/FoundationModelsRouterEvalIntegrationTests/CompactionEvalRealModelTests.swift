import Evaluations
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

// MARK: - Real-model eval

/// Loads ``CompactionEvalRealModel`` at most once for the real-model `@Test`
/// below — declared at file scope (not a suite member) so it can be
/// referenced directly from the `.evaluates(...)` trait argument, which is
/// evaluated synchronously when the test is registered, long before this
/// runner's own model load (deferred to its first `run(entries:prompt:budget:question:)`
/// call, well inside the async `run()` the trait drives).
private let compactionEvalSubsetRunner = CompactionEvalRealSubjectRunner(
    seeds: compactionEvalRepresentativeSeeds)

/// The tier's evaluation: the runner's own seeds folded with the router's
/// default compaction prompt against a budget whose target is small enough to
/// force the model-assisted `Summarization` stage (see
/// ``CompactionEvaluation/init(prompt:budget:seeds:includesJudgedDimensions:runSubject:)``'s
/// own doc comment).
///
/// The seed set comes from the runner rather than from a second statement, so
/// the tier can never evaluate one set of seeds while its runner numbers its
/// progress lines and reads its unreached list against another.
///
/// `includesJudgedDimensions` is `false`: the gated tier does not compute the
/// judged `Faithfulness`/`Continuability` means — it measures LESS than a judged
/// run. No assertion ever read those means, and the judge's
/// `SystemLanguageModel` calls cost about 2.7 seconds per sample (measured
/// 2026-08-19), which alone held the whole-dataset tier of the day over task
/// ^k0d30s4's two-minute budget. Construct a `CompactionEvaluation` with the
/// default `includesJudgedDimensions: true` to score the judged dimensions
/// again.
///
/// Built here rather than by a factory. A factory took the runner as an
/// argument while TWO tiers each built one of these; task ^k0d30s4 deleted the
/// whole-dataset tier, so one caller was left and the argument had one value.
private let compactionEvalSubsetEvaluation = CompactionEvaluation(
    seeds: compactionEvalSubsetRunner.seeds, includesJudgedDimensions: false
) { entries, prompt, budget, question in
    try await compactionEvalSubsetRunner.run(
        entries: entries, prompt: prompt, budget: budget, question: question)
}

/// States the bar ``expectFactRetention(of:)`` really applied.
///
/// Both of that function's assertions divide by the samples the run MEASURED,
/// and a run its time limit cuts short measures fewer samples than its tier
/// holds seeds. A message that quoted the TIER's seed count alone would name a
/// bar the assertion never used: at six measured samples the floor needs six,
/// where the seven-seed tier needs seven, so a reader of the failing message
/// counted the shortfall against the wrong denominator (task ^xscp198).
///
/// The assertions themselves are right to divide by what ran. A run cut short
/// already fails on its own time limit, so applying the tier's bar to a partial
/// measurement would report a fact-retention defect for a run that only ran out
/// of clock. The defect was in the message, and this states what was applied.
///
/// - Parameters:
///   - floor: The floor the assertion applied —
///     ``compactionEvalSummaryFactRetentionFloor`` or
///     ``compactionEvalAnswerFactRetentionFloor``, because the two sides
///     state different measured baselines.
///   - measured: How many samples the run recorded.
///   - total: How many seeds the tier holds.
/// - Returns: The sentence, which names the tier's own bar as well when the run
///   recorded fewer samples than the tier holds.
private func compactionEvalFactRetentionBar(floor: Double, measured: Int, of total: Int) -> String {
    let required = compactionEvalFactRetentionRequiredSamples(of: measured, floor: floor)
    let applied = "a floor of \(floor)"
        + " over the \(measured) samples this run measured needs \(required) of them"
    guard measured < total else { return applied }
    let whole = compactionEvalFactRetentionRequiredSamples(of: total, floor: floor)
    return applied
        + ", and the run stopped short of the tier's \(total) seeds, which need \(whole)"
}

/// Prints the tier's per-sample evidence, then asserts the two bars its samples
/// are held to.
///
/// Two assertions rather than one, because the tier spans two steps. The FOLD
/// has to write a summary carrying the planted fact, and the resumed session has
/// then to ANSWER with it. Each is held to its own measured floor —
/// ``compactionEvalSummaryFactRetentionFloor`` and
/// ``compactionEvalAnswerFactRetentionFloor``; see those values for the
/// measurement each one states, and for why they stay two constants even on
/// a day they hold the same number — and each states, in its own message, how
/// many samples cleared it beside the bar the assertion really applied. See
/// ``compactionEvalFactRetentionBar(floor:measured:of:)`` for why that bar is
/// read off the measured count rather than off the tier's seed count.
///
/// - Parameter runner: The tier's runner, holding the evidence its samples
///   recorded and the seed set that evidence is read against — so a run the
///   time limit cut short states the seeds it never reached.
private func expectFactRetention(of runner: CompactionEvalRealSubjectRunner) async {
    // Printed before the assertions so a run that misses a bar still
    // leaves the evidence behind: a mean alone cannot say whether a
    // failing sample lost its fact in the fold or in the answering turn,
    // and this table classifies every sample on exactly that question.
    let seeds = runner.seeds
    let findings = CompactionEvalFactRetentionReport.findings(
        for: await runner.recordedDiagnostics(),
        seeds: seeds
    )
    for line in CompactionEvalFactRetentionReport.lines(of: findings, expecting: seeds) {
        print(line)
    }

    let measured = findings.count

    // The COMPACTION side, asserted first because it is the necessary
    // condition: a tier whose folds dropped the fact can never answer with it.
    let summaryCarried = CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings)
    let summaryBar = compactionEvalFactRetentionBar(
        floor: compactionEvalSummaryFactRetentionFloor, measured: measured, of: seeds.count)
    #expect(
        CompactionEvalFactRetentionReport.share(of: summaryCarried, over: measured)
            >= compactionEvalSummaryFactRetentionFloor,
        "\(summaryCarried) of \(measured) folds wrote a summary carrying the fact, and \(summaryBar)"
    )

    // The end-to-end bar, read off the framework's own metric rather than off
    // the table, so this assertion and `FactRetention` can never disagree.
    let result = EvaluationContext.current.result
    let answerCarried = CompactionEvalFactRetentionReport.counts(of: findings)[.retained] ?? 0
    let answerBar = compactionEvalFactRetentionBar(
        floor: compactionEvalAnswerFactRetentionFloor, measured: measured, of: seeds.count)
    #expect(
        result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention))
            >= compactionEvalAnswerFactRetentionFloor,
        "\(answerCarried) of \(measured) answers carried the fact, and \(answerBar)"
    )
}

/// The real-model fact-retention eval (compaction_plan.md §5's
/// `@Test(.evaluates(...))` sketch): folds each seed of
/// ``compactionEvalRepresentativeSeeds`` with the router's default compaction
/// prompt, resumes a session over each result, asks its question, and asserts
/// the summary and answer fact-retention shares against
/// ``compactionEvalSummaryFactRetentionFloor`` and
/// ``compactionEvalAnswerFactRetentionFloor``.
///
/// The model is ``CompactionEvalRealModel`` — a small model since task
/// ^k0d30s4's two-minute budget, and Qwen2.5-3B-Instruct since task ^m03heaa;
/// that constant states what each swap no longer proves. The floors are the
/// current canary's measured baselines; the 30B model's 0.9 bar is not
/// measured here any more.
///
/// The TARGET is what selects this suite, and it carries no `.enabled(if:)` of
/// its own — see ``GatedEvalSerialGate`` for the commands that ask for this
/// target. It never runs on a network/GPU-less box because nothing there names
/// the real-model targets.
///
/// ## What it NO LONGER proves (task ^k0d30s4)
///
/// A second tier folded 24 hand-written fixtures until 2026-08-21, and this one
/// folded seven of them. 24 seeds cost more than six minutes at the canary's own
/// measured rate, so that tier could not hold the two-minute budget for every
/// integration test, and the answer was to make the test smaller: the tier went,
/// and the seventeen fixtures no other tier folded went with it. So no gated run
/// measures the fold against a fixture outside these seven any more. What the
/// seven still span is stated by ``compactionEvalRepresentativeSubsetIDs`` and
/// held mechanically by `CompactionEvalRepresentativeSubsetTests`, and
/// ``compactionEvalSubsetTimeLimitMinutes`` carries the measurement behind the
/// limit.
///
/// This suite was long described here as blocked by an MLX `default.metallib`
/// load failure that no real-model suite in this repository could get past.
/// That was wrong: the failure was a resource-colocation bug in `swift test`'s
/// binary layout, which ``MetalLibraryTestBootstrap`` now fixes from inside
/// ``GatedRealModelSuiteTrait``, this suite's own trait.
///
/// `.exclusiveResidentModel(of:)` holds this suite's real model exclusive
/// against
/// every other real-model eval suite and evicts it when the suite ends, and
/// ``compactionEvalSubsetTimeLimitMinutes`` bounds a hung real-model load — see
/// ``GatedEvalSerialGate`` for why the target needs both.
@Suite(
    .exclusiveResidentModel(of: compactionEvalSubsetRunner),
    .timeLimit(.minutes(compactionEvalSubsetTimeLimitMinutes))
)
struct CompactionEvaluationIntegrationTests {
    @Test(
        "Compaction retains pre-fold facts",
        .evaluates(
            compactionEvalSubsetEvaluation,
            info: ["promptName": CompactionPrompt.default.name]
        )
    )
    func evaluateCompaction() async {
        await expectFactRetention(of: compactionEvalSubsetRunner)
    }
}
