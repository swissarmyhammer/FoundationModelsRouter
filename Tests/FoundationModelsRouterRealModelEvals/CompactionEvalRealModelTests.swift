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

/// The whole-dataset tier's own runner, for the same reason
/// ``compactionEvalSubsetRunner`` is declared at file scope.
///
/// A second instance rather than a shared one. A runner accumulates its own
/// per-sample evidence, and the two tiers report separate tables, so sharing one
/// would let a table carry samples the other tier ran. The everyday command
/// runs one of the two tiers, and a runner that never runs loads no model.
private let compactionEvalFullDatasetRunner = CompactionEvalRealSubjectRunner(seeds: compactionEvalSeeds)

/// Builds a tier's evaluation: the runner's own seeds folded with the
/// router's default compaction prompt against a budget whose target is small
/// enough to force the model-assisted `Summarization` stage (see
/// ``CompactionEvaluation/init(prompt:budget:seeds:runSubject:)``'s own doc
/// comment).
///
/// The seed set comes from the runner rather than from a second argument, so
/// one tier can never evaluate one set of seeds while its runner numbers its
/// progress lines and reads its unreached list against another.
///
/// - Parameter runner: The runner whose resident model folds its seeds and
///   answers their questions.
/// - Returns: The evaluation, ready to hand to `.evaluates(...)`.
private func makeCompactionEvalRealEvaluation(
    driving runner: CompactionEvalRealSubjectRunner
) -> CompactionEvaluation {
    CompactionEvaluation(seeds: runner.seeds) { entries, prompt, budget, question in
        try await runner.run(entries: entries, prompt: prompt, budget: budget, question: question)
    }
}

/// The default tier's evaluation, over ``compactionEvalRepresentativeSeeds``.
private let compactionEvalSubsetEvaluation = makeCompactionEvalRealEvaluation(
    driving: compactionEvalSubsetRunner)

/// The opt-in tier's evaluation, over every hand-written fixture.
private let compactionEvalFullDatasetEvaluation = makeCompactionEvalRealEvaluation(
    driving: compactionEvalFullDatasetRunner)

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
///   - measured: How many samples the run recorded.
///   - total: How many seeds the tier holds.
/// - Returns: The sentence, which names the tier's own bar as well when the run
///   recorded fewer samples than the tier holds.
private func compactionEvalFactRetentionBar(measured: Int, of total: Int) -> String {
    let required = compactionEvalFactRetentionRequiredSamples(of: measured)
    let applied = "a floor of \(compactionEvalFactRetentionFloor)"
        + " over the \(measured) samples this run measured needs \(required) of them"
    guard measured < total else { return applied }
    let whole = compactionEvalFactRetentionRequiredSamples(of: total)
    return applied
        + ", and the run stopped short of the tier's \(total) seeds, which need \(whole)"
}

/// Prints one tier's per-sample evidence, then asserts the two bars its samples
/// are held to.
///
/// Shared by both tiers so the two can never drift into measuring the same
/// metric two ways.
///
/// Two assertions rather than one, because the tier spans two steps. The FOLD
/// has to write a summary carrying the planted fact, and the resumed session has
/// then to ANSWER with it. Both are held to
/// ``compactionEvalFactRetentionFloor`` — see that value for why one number
/// serves both — and each states, in its own message, how many samples cleared
/// it beside the bar the assertion really applied. See
/// ``compactionEvalFactRetentionBar(measured:of:)`` for why that bar is read off
/// the measured count rather than off the tier's seed count.
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
    let bar = compactionEvalFactRetentionBar(measured: measured, of: seeds.count)

    // The COMPACTION side, asserted first because it is the necessary
    // condition: a tier whose folds dropped the fact can never answer with it.
    let summaryCarried = CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings)
    #expect(
        CompactionEvalFactRetentionReport.share(of: summaryCarried, over: measured)
            >= compactionEvalFactRetentionFloor,
        "\(summaryCarried) of \(measured) folds wrote a summary carrying the fact, and \(bar)"
    )

    // The end-to-end bar, read off the framework's own metric rather than off
    // the table, so this assertion and `FactRetention` can never disagree.
    let result = EvaluationContext.current.result
    let answerCarried = CompactionEvalFactRetentionReport.counts(of: findings)[.retained] ?? 0
    #expect(
        result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= compactionEvalFactRetentionFloor,
        "\(answerCarried) of \(measured) answers carried the fact, and \(bar)"
    )
}

/// The DEFAULT real-model eval (compaction_plan.md §5's
/// `@Test(.evaluates(...))` sketch): folds each seed of
/// ``compactionEvalRepresentativeSeeds`` with the router's default compaction
/// prompt, resumes a session over each result, asks its question, and asserts
/// mean `FactRetention` over the subset is at least
/// ``compactionEvalFactRetentionFloor``.
///
/// The TARGET is what selects this suite, and it carries no `.enabled(if:)` of
/// its own — see ``GatedEvalSerialGate`` for the commands that ask for this
/// target and the command that leaves it out. It never runs on a
/// network/GPU-less box because nothing there names the real-model targets.
///
/// It measures a subset rather than the whole dataset because the whole dataset
/// does not fit a limit anyone runs by habit — see
/// ``compactionEvalRepresentativeSubsetIDs`` for what the subset carries and
/// ``compactionEvalSubsetTimeLimitMinutes`` for the measurement behind its
/// limit. ``CompactionEvalFullDatasetIntegrationTests`` is the whole-dataset
/// tier, and the everyday command steps that tier aside with one
/// `--skip CompactionEvalFullDataset` rather than measuring the same seeds
/// twice.
///
/// This suite was long described here as blocked by an MLX `default.metallib`
/// load failure that no real-model suite in this repository could get past.
/// That was wrong: the failure was a resource-colocation bug in `swift test`'s
/// binary layout, which ``MetalLibraryTestBootstrap`` now fixes from inside
/// ``GatedEvalResidencyTrait``, this suite's own trait.
///
/// ``GatedEvalResidencyTrait`` holds this suite's real model exclusive against
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

/// The opt-in whole-dataset tier of the same eval: every hand-written fixture,
/// held to the same ``compactionEvalFactRetentionFloor``.
///
/// Its dataset is a superset of the default tier's, so an everyday real-model
/// run steps it aside rather than measuring the same seeds twice ahead of it:
/// the command carries `--skip CompactionEvalFullDataset` beside its
/// `--filter FoundationModelsRouterRealModel`. Ask for this tier by naming it,
/// with `swift test --filter CompactionEvalFullDataset`. Its limit is
/// ``compactionEvalFullDatasetTimeLimitMinutes``, which is why the everyday run
/// does not pay for it.
///
/// Named so it does not carry `CompactionEvaluationIntegrationTests` as a
/// substring: `swift test --filter` takes a regular expression, and a name that
/// contained the default tier's would make the everyday targeted command select
/// both tiers.
@Suite(
    .exclusiveResidentModel(of: compactionEvalFullDatasetRunner),
    .timeLimit(.minutes(compactionEvalFullDatasetTimeLimitMinutes))
)
struct CompactionEvalFullDatasetIntegrationTests {
    @Test(
        "Compaction retains pre-fold facts across the whole dataset",
        .evaluates(
            compactionEvalFullDatasetEvaluation,
            info: ["promptName": CompactionPrompt.default.name]
        )
    )
    func evaluateCompactionOverEverySeed() async {
        await expectFactRetention(of: compactionEvalFullDatasetRunner)
    }
}
