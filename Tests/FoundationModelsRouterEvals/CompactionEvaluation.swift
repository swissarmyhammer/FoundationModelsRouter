import Evaluations
import FoundationModels

@testable import FoundationModelsRouter

/// The shared ``Metric``/``ScoreDimension`` identities every
/// ``CompactionEvaluation`` instance's ``CompactionEvaluation/evaluators``,
/// ``CompactionEvaluation/aggregateMetrics(using:)``, and the gated
/// `@Test`'s own assertion all construct independently — ``Metric``/
/// ``ScoreDimension`` are plain value types with no shared identity beyond
/// their `name`, so every call site must build an equal one from the same
/// name rather than share a stored instance across API boundaries.
enum CompactionEvalMetric {
    /// The mechanical metric checking whether the resumed session's answer
    /// contains the sample's ``CompactionEvaluationOutcome/factKeyPhrase`` —
    /// pass/fail per sample, aggregated as a mean by
    /// ``CompactionEvaluation/aggregateMetrics(using:)`` and asserted `>= 0.9`
    /// by the gated `@Test`.
    static let factRetention = Metric("FactRetention")

    /// The mechanical metric checking whether the fold's produced
    /// `tokensAfter` stayed at or under the sample's
    /// ``CompactionEvaluationOutcome/targetTokens`` — pass/fail per sample,
    /// aggregated as a mean by ``CompactionEvaluation/aggregateMetrics(using:)``.
    static let underTarget = Metric("UnderTarget")

    /// The four-point scale both judged dimensions score on (compaction_plan.md
    /// §5's `ModelJudgeEvaluator` sketch).
    private static let fourPointScale: [Double: String] = [
        1.0: "Poor — contradicts or invents facts not in the original conversation",
        2.0: "Weak — misses or garbles significant content",
        3.0: "Good — preserves the important content with minor omissions",
        4.0: "Excellent — precise and complete",
    ]

    /// The judged dimension scoring whether the fold's summary states only
    /// facts present in the original conversation — one of the two
    /// `ModelJudgeEvaluator` dimensions ``CompactionEvaluation/evaluators``
    /// registers.
    static let faithfulness = ScoreDimension(
        "Faithfulness",
        description: "The summary states only facts present in the original conversation.",
        scale: .numeric(fourPointScale)
    )

    /// The judged dimension scoring whether next steps and constraints
    /// survive the fold well enough to resume work — the other
    /// `ModelJudgeEvaluator` dimension ``CompactionEvaluation/evaluators``
    /// registers.
    static let continuability = ScoreDimension(
        "Continuability",
        description: "Next steps and constraints survive well enough to resume work.",
        scale: .numeric(fourPointScale)
    )
}

/// What ``CompactionEvaluation/subject(from:)`` failed to do.
enum CompactionEvaluationError: Error {
    /// A sample's `expected.seedID` did not match any seed this evaluation
    /// was constructed with — unreachable in practice, since
    /// ``CompactionEvaluation/dataset`` always stamps a `seedID` it also
    /// registered in ``CompactionEvaluation/init(prompt:budget:seeds:runSubject:)``.
    case unknownSeed(String)

    /// A sample carried no `expected` value at all — unreachable in practice,
    /// since ``CompactionEvaluation/dataset`` always supplies one.
    case missingExpectedValue

    /// A real model loader resolved something other than the expected
    /// concrete container type — see ``CompactionEvalRealSubjectRunner``.
    case unexpectedContainerType
}

/// The compaction-quality evaluation (compaction_plan.md §5): plants a fact in
/// a seed transcript's foldable head, folds it with ``prompt``/``budget``,
/// resumes a session over the result, and asks the seed's question —
/// answerable only from the folded content.
///
/// ``prompt`` is a stored parameter, not baked into the type, so pointing this
/// evaluation at a different ``CompactionPrompt`` (the segment records the
/// prompt name — compaction_plan.md §2) is constructing a different
/// `CompactionEvaluation` value, never a different type: the hill-climbing
/// loop compaction_plan.md §5 describes is literally
/// `CompactionEvaluation(prompt: candidate)` vs. `CompactionEvaluation(prompt: .default)`.
///
/// The actual compaction + resumed-session-question work is injected via
/// ``runSubject`` rather than hardwired to a live model, so:
/// - A hermetic test wires in a fake closure (no real inference) to prove the
///   dataset loads and the subject closure wires up
///   (``CompactionEvaluationTests``).
/// - The gated `@Test` wires in a closure that drives a real resident MLX
///   model through the exact bare-session recipe compaction_plan.md §1.5
///   describes: ``Compactor/compact(_:prompt:budget:summarizer:)`` over the
///   seed's entries, then a live session resumed over the folded transcript.
struct CompactionEvaluation: Evaluation {
    /// The expected/ground-truth sample type the `Evaluation` protocol
    /// requires — Apple's own `ModelSample` wrapping
    /// ``CompactionEvaluationOutcome``, so `Sample.ExpectedValue ==
    /// Subject.Value` as `Evaluation` demands.
    typealias Sample = ModelSample<CompactionEvaluationOutcome>
    /// The produced/actual result type the `Evaluation` protocol requires —
    /// Apple's own `ModelSubject` wrapping the same
    /// ``CompactionEvaluationOutcome`` a sample's `expected` value uses.
    typealias Subject = ModelSubject<CompactionEvaluationOutcome>

    /// The compaction prompt under test — recorded into every sample's
    /// `expected.promptName` and every produced outcome's `promptName` alike,
    /// so results are always attributable to the exact prompt that produced
    /// them.
    let prompt: CompactionPrompt

    /// The token budget every sample folds against.
    let budget: TokenBudget

    /// Runs one sample's actual subject work: compacts `entries` with
    /// `prompt`/`budget`, resumes a session over the result, asks `question`.
    /// Injected so this evaluation's behavior is identical in shape whether
    /// the model behind it is a hermetic fake or a real resident model — see
    /// this type's own doc comment.
    let runSubject:
        @Sendable (
            _ entries: [Transcript.Entry],
            _ prompt: CompactionPrompt,
            _ budget: TokenBudget,
            _ question: String
        ) async throws -> (answer: String, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String])

    /// Every seed this evaluation draws samples from, keyed by
    /// ``CompactionEvalSeed/id`` so ``subject(from:)`` can look the full seed
    /// (its `Transcript.Entry` values) back up from a sample's `seedID`.
    private let seedsByID: [String: CompactionEvalSeed]

    /// Creates a compaction evaluation.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt under test. Defaults to
    ///     ``CompactionPrompt/default``.
    ///   - budget: The token budget every sample folds against. Defaults to a
    ///     budget whose `target` is small enough that the untouched recency
    ///     window alone still exceeds it — guaranteeing the pipeline falls
    ///     through to the model-assisted `Summarization` stage rather than
    ///     stopping at `TurnTruncation` (which would drop the planted fact
    ///     with no trace at all — see ``CompactionEvalSeed``'s doc comment).
    ///   - seeds: The seed transcripts to draw samples from. Defaults to
    ///     ``compactionEvalSeeds`` (every hand-written fixture).
    ///   - runSubject: Runs one sample's subject work — see ``runSubject``.
    init(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget = TokenBudget(limit: 4000, trigger: 0.80, target: 0.05),
        seeds: [CompactionEvalSeed] = compactionEvalSeeds,
        runSubject: @escaping @Sendable (
            _ entries: [Transcript.Entry],
            _ prompt: CompactionPrompt,
            _ budget: TokenBudget,
            _ question: String
        ) async throws -> (answer: String, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String])
    ) {
        self.prompt = prompt
        self.budget = budget
        self.seedsByID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0) })
        self.runSubject = runSubject
    }

    /// The `Evaluation` protocol's sample loader: one ``Sample`` per seed in
    /// ``seedsByID``, each pairing the seed's question with a
    /// ``CompactionEvaluationOutcome`` ground truth — the planted fact, its
    /// key phrase, the fold's target token count, and this evaluation's
    /// ``prompt`` name.
    var dataset: ArrayLoader<Sample> {
        let targetTokens = Int((Double(budget.limit) * budget.target).rounded())
        let samples = seedsByID.values.sorted { $0.id < $1.id }.map { seed in
            ModelSample(
                prompt: seed.question,
                expected: CompactionEvaluationOutcome(
                    seedID: seed.id,
                    plantedFact: seed.plantedFact,
                    factKeyPhrase: seed.factKeyPhrase,
                    targetTokens: targetTokens,
                    promptName: prompt.name
                )
            )
        }
        return ArrayLoader(samples: samples)
    }

    /// The `Evaluation` protocol's per-sample subject work: looks the full
    /// seed back up by `sample.expected.seedID`, runs ``runSubject`` to
    /// compact its entries, resume a session over the result, and ask its
    /// question, then wraps the produced answer and token counts in a
    /// ``Subject``.
    ///
    /// - Parameter sample: The sample to produce a subject result for.
    /// - Returns: The subject carrying the produced answer, token counts, and
    ///   applied compaction stages.
    /// - Throws: ``CompactionEvaluationError/missingExpectedValue`` if
    ///   `sample` carries no `expected` value, or
    ///   ``CompactionEvaluationError/unknownSeed(_:)`` if `expected.seedID`
    ///   matches no seed this evaluation was constructed with.
    func subject(from sample: Sample) async throws -> Subject {
        guard let expected = sample.expected else { throw CompactionEvaluationError.missingExpectedValue }
        guard let seed = seedsByID[expected.seedID] else {
            throw CompactionEvaluationError.unknownSeed(expected.seedID)
        }

        let produced = try await runSubject(seed.entries, prompt, budget, seed.question)

        return ModelSubject(
            value: CompactionEvaluationOutcome(
                seedID: seed.id,
                plantedFact: expected.plantedFact,
                factKeyPhrase: expected.factKeyPhrase,
                targetTokens: expected.targetTokens,
                promptName: prompt.name,
                answer: produced.answer,
                tokensBefore: produced.tokensBefore,
                tokensAfter: produced.tokensAfter,
                stagesApplied: produced.stagesApplied
            )
        )
    }

    /// Rationale used by both mechanical evaluators below when a sample
    /// unexpectedly carries no `expected` value — extracted so the two
    /// copies can't drift out of sync.
    private static let sampleCarriedNoExpectedValueMessage = "sample carried no expected value"

    /// The evaluators this evaluation registers: mechanical `FactRetention`
    /// and `UnderTarget` metrics computed directly from each sample/subject
    /// pair, plus a `ModelJudgeEvaluator` scoring the
    /// ``CompactionEvalMetric/faithfulness`` and
    /// ``CompactionEvalMetric/continuability`` quality dimensions.
    var evaluators: Evaluators {
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionEvalMetric.factRetention.failing(rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            // Checks the answer for the short key phrase, never the whole
            // `plantedFact` sentence: a short, targeted answer can never
            // contain an entire long declarative sentence as a substring, so
            // checking the full sentence here would make this metric fail
            // unconditionally regardless of whether compaction actually
            // preserved the fact (see `factKeyPhrase`'s own doc comment).
            return subject.value.answer.localizedCaseInsensitiveContains(expected.factKeyPhrase)
                ? CompactionEvalMetric.factRetention.passing(rationale: "fact survived the fold")
                : CompactionEvalMetric.factRetention.failing(rationale: subject.value.answer)
        }
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionEvalMetric.underTarget.failing(rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            return subject.value.tokensAfter <= expected.targetTokens
                ? CompactionEvalMetric.underTarget.passing()
                : CompactionEvalMetric.underTarget.failing(
                    rationale: "tokensAfter \(subject.value.tokensAfter) > target \(expected.targetTokens)")
        }
        // `judge` defaults to `SystemLanguageModel()` (Apple's own default —
        // see the installed `Evaluations.framework` interface), a cheap,
        // synchronous construction that defers all real work to its first
        // actual generation call, well after this computed property is
        // built. Never accessed by the hermetic tests in this target (they
        // call `dataset`/`subject(from:)` directly, never `evaluators`/`run()`),
        // so building it here carries no hermeticity risk.
        ModelJudgeEvaluator<Sample>(
            dimensions: [CompactionEvalMetric.faithfulness, CompactionEvalMetric.continuability]
        )
    }

    /// Registers all four metrics — `FactRetention`, `UnderTarget`,
    /// `Faithfulness`, and `Continuability` — for mean aggregation, as the
    /// `Evaluation` protocol requires.
    ///
    /// - Parameter aggregator: The aggregator to register the four metrics
    ///   with.
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: CompactionEvalMetric.factRetention)
        aggregator.computeMean(of: CompactionEvalMetric.underTarget)
        aggregator.computeMean(of: CompactionEvalMetric.faithfulness.metric)
        aggregator.computeMean(of: CompactionEvalMetric.continuability.metric)
    }
}
