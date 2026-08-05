import Evaluations

@testable import FoundationModelsRouter

/// The shared ``Metric`` identities every ``CompactionContinuityEvaluation``
/// instance's ``CompactionContinuityEvaluation/evaluators``,
/// ``CompactionContinuityEvaluation/aggregateMetrics(using:)``, and the gated
/// `@Test`'s own assertion all construct independently — see
/// ``CompactionEvalMetric``'s own doc comment for why every call site must
/// build an equal ``Metric`` from the same name rather than share a stored
/// instance.
///
/// All five are mechanical (task 4ce0a1k specifies mechanical evaluators
/// only for this evaluation, unlike ``CompactionEvaluation``'s additional
/// `ModelJudgeEvaluator` dimensions) — each is computed directly from a
/// sample/subject pair, never judged.
enum CompactionContinuityMetric {
    /// Whether the produced ``CompactionContinuityOutcome/finalAnswer``
    /// contains **every** one of the sample's
    /// ``CompactionContinuityOutcome/expectedKeyPhrases`` — the strict,
    /// whole-task-correct check.
    static let answersCorrect = Metric("AnswersCorrect")

    /// Whether at least one live fold actually ran while driving the task's
    /// steps (``CompactionContinuityOutcome/foldCount`` `>= 1`) — the
    /// mechanical proof that this dataset's own "sized to be impossible
    /// without >=1 fold" claim held for this run, not just asserted at
    /// authoring time.
    static let foldOccurred = Metric("FoldOccurred")

    /// Whether the produced ``CompactionContinuityOutcome/finalAnswer``
    /// contains **at least one** of the sample's
    /// ``CompactionContinuityOutcome/factKeyPhrases`` — a looser check than
    /// ``answersCorrect``: a task can fail the strict whole-task check while
    /// still showing partial continuity (one fact survived the fold(s), even
    /// if not both), which this metric surfaces independently.
    static let factsSurvived = Metric("FactsSurvived")

    /// Whether the produced ``CompactionContinuityOutcome/tokensAfter``
    /// stayed at or under the sample's
    /// ``CompactionContinuityOutcome/targetTokens`` — mirrors
    /// ``CompactionEvalMetric/underTarget``.
    static let budgetHeld = Metric("BudgetHeld")

    /// Whether the produced ``CompactionContinuityOutcome/recordedEntryCount``
    /// met or exceeded the sample's
    /// ``CompactionContinuityOutcome/expectedMinimumRecordedEntries`` — proof
    /// that whatever the live session folded away from its own resumable
    /// window, the durable recording underneath it still holds the whole
    /// task's history, exactly as compaction_plan.md's checkpointed-window
    /// vs. full-history split promises.
    static let recordingComplete = Metric("RecordingComplete")
}

/// What ``CompactionContinuityEvaluation/subject(from:)`` failed to do.
enum CompactionContinuityEvaluationError: Error {
    /// A sample's `expected.taskID` did not match any task this evaluation
    /// was constructed with — unreachable in practice, since
    /// ``CompactionContinuityEvaluation/dataset`` always stamps a `taskID`
    /// it also registered in
    /// ``CompactionContinuityEvaluation/init(prompt:budget:tasks:runSubject:)``.
    case unknownTask(String)

    /// A sample carried no `expected` value at all — unreachable in practice,
    /// since ``CompactionContinuityEvaluation/dataset`` always supplies one.
    case missingExpectedValue

    /// A real model loader resolved something other than the expected
    /// concrete container type — mirrors
    /// ``CompactionEvaluationError/unexpectedContainerType``.
    case unexpectedContainerType
}

/// The compaction-continuity evaluation (task 4ce0a1k): drives a
/// multi-step task's steps through a real session vended with a small
/// ``budget`` (task 8213x39's auto-compaction opt-in), one step at a time,
/// then asks a final instruction whose correct completion requires
/// combining facts planted in earlier steps — answerable only if the
/// session *remained usable and continuable* across whatever folds its own
/// budget forced along the way.
///
/// This is a different concern than ``CompactionEvaluation``'s: that
/// evaluation folds one static, pre-built transcript exactly once and then
/// asks a single question of the fold's own summary quality (fact
/// retention). This evaluation instead drives a live, multi-turn session
/// end to end — the dataset is sized so at least one fold is forced
/// somewhere in the middle of the task, not staged as the whole point of a
/// single call — and measures whether the *session itself* stayed
/// continuable, not just whether one fold's summary read well.
///
/// ``prompt`` is a stored parameter, not baked into the type, for the exact
/// same reason ``CompactionEvaluation/prompt`` is: pointing this evaluation
/// at a different ``CompactionPrompt`` is constructing a different
/// `CompactionContinuityEvaluation` value from a differently-constructed
/// session, never a different type — "comparing fold prompts = same
/// Evaluation, differently constructed sessions" (task 4ce0a1k).
///
/// The actual multi-step session-driving work is injected via ``runSubject``
/// rather than hardwired to a live model, mirroring
/// ``CompactionEvaluation/runSubject``'s own hermetic/gated split.
struct CompactionContinuityEvaluation: Evaluation {
    /// The expected/ground-truth sample type the `Evaluation` protocol
    /// requires.
    typealias Sample = ModelSample<CompactionContinuityOutcome>
    /// The produced/actual result type the `Evaluation` protocol requires.
    typealias Subject = ModelSubject<CompactionContinuityOutcome>

    /// The compaction prompt every fold this evaluation's sessions perform
    /// sends to their summarizer — recorded into every sample's
    /// `expected.promptName` and every produced outcome's `promptName`
    /// alike. See this type's own doc comment.
    let prompt: CompactionPrompt

    /// The auto-compaction budget every session this evaluation drives is
    /// vended with (task 8213x39's `makeSession(budget:)` opt-in).
    let budget: TokenBudget

    /// Runs one sample's actual subject work: drives `steps` through a
    /// session vended with `prompt`/`budget` one at a time, then asks
    /// `finalInstruction`. Injected so this evaluation's behavior is
    /// identical in shape whether the model behind it is a hermetic fake or
    /// a real resident model — see this type's own doc comment.
    let runSubject:
        @Sendable (
            _ steps: [String],
            _ finalInstruction: String,
            _ prompt: CompactionPrompt,
            _ budget: TokenBudget
        ) async throws -> (
            finalAnswer: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int, recordedEntryCount: Int,
            modelName: String
        )

    /// Every task this evaluation draws samples from, keyed by
    /// ``CompactionContinuitySeed/id`` so ``subject(from:)`` can look the
    /// full task (its steps) back up from a sample's `taskID`.
    private let tasksByID: [String: CompactionContinuitySeed]

    /// Creates a compaction-continuity evaluation.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt under test. Defaults to
    ///     ``CompactionPrompt/default``.
    ///   - budget: The auto-compaction budget every session this evaluation
    ///     drives is vended with. Defaults to a budget small enough that
    ///     every hand-written task (see ``compactionContinuityTaskSpecs``)
    ///     forces at least one live fold before its final instruction.
    ///   - tasks: The task fixtures to draw samples from. Defaults to
    ///     ``compactionContinuitySeeds`` (every hand-written fixture).
    ///   - runSubject: Runs one sample's subject work — see ``runSubject``.
    init(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget = TokenBudget(limit: 2048, trigger: 0.80, target: 0.30),
        tasks: [CompactionContinuitySeed] = compactionContinuitySeeds,
        runSubject: @escaping @Sendable (
            _ steps: [String],
            _ finalInstruction: String,
            _ prompt: CompactionPrompt,
            _ budget: TokenBudget
        ) async throws -> (
            finalAnswer: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int, recordedEntryCount: Int,
            modelName: String
        )
    ) {
        self.prompt = prompt
        self.budget = budget
        self.tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        self.runSubject = runSubject
    }

    /// The `Evaluation` protocol's sample loader: one ``Sample`` per task in
    /// ``tasksByID``, each pairing the task's final instruction with a
    /// ``CompactionContinuityOutcome`` ground truth.
    var dataset: ArrayLoader<Sample> {
        let targetTokens = Int((Double(budget.limit) * budget.target).rounded())
        let samples = tasksByID.values.sorted { $0.id < $1.id }.map { task in
            ModelSample(
                prompt: task.finalInstruction,
                expected: CompactionContinuityOutcome(
                    taskID: task.id,
                    factKeyPhrases: task.factKeyPhrases,
                    expectedKeyPhrases: task.expectedKeyPhrases,
                    targetTokens: targetTokens,
                    expectedMinimumRecordedEntries: task.expectedMinimumRecordedEntries,
                    promptName: prompt.name
                )
            )
        }
        return ArrayLoader(samples: samples)
    }

    /// The `Evaluation` protocol's per-sample subject work: looks the full
    /// task back up by `sample.expected.taskID`, runs ``runSubject`` to
    /// drive its steps and ask its final instruction, then wraps the
    /// produced answer, fold accounting, and recording completeness in a
    /// ``Subject``.
    ///
    /// - Parameter sample: The sample to produce a subject result for.
    /// - Returns: The subject carrying the produced answer, fold counts, and
    ///   recorded-entry count.
    /// - Throws: ``CompactionContinuityEvaluationError/missingExpectedValue``
    ///   if `sample` carries no `expected` value, or
    ///   ``CompactionContinuityEvaluationError/unknownTask(_:)`` if
    ///   `expected.taskID` matches no task this evaluation was constructed
    ///   with.
    func subject(from sample: Sample) async throws -> Subject {
        guard let expected = sample.expected else {
            throw CompactionContinuityEvaluationError.missingExpectedValue
        }
        guard let task = tasksByID[expected.taskID] else {
            throw CompactionContinuityEvaluationError.unknownTask(expected.taskID)
        }

        let produced = try await runSubject(task.steps, task.finalInstruction, prompt, budget)

        return ModelSubject(
            value: CompactionContinuityOutcome(
                taskID: task.id,
                factKeyPhrases: expected.factKeyPhrases,
                expectedKeyPhrases: expected.expectedKeyPhrases,
                targetTokens: expected.targetTokens,
                expectedMinimumRecordedEntries: expected.expectedMinimumRecordedEntries,
                promptName: prompt.name,
                finalAnswer: produced.finalAnswer,
                foldCount: produced.foldCount,
                tokensBefore: produced.tokensBefore,
                tokensAfter: produced.tokensAfter,
                recordedEntryCount: produced.recordedEntryCount,
                modelName: produced.modelName
            )
        )
    }

    /// Rationale used by every mechanical evaluator below when a sample
    /// unexpectedly carries no `expected` value — extracted so the five
    /// copies can't drift out of sync. Mirrors
    /// `CompactionEvaluation.sampleCarriedNoExpectedValueMessage`.
    private static let sampleCarriedNoExpectedValueMessage = "sample carried no expected value"

    /// The five mechanical evaluators this evaluation registers — see
    /// ``CompactionContinuityMetric``'s own case-by-case documentation.
    var evaluators: Evaluators {
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionContinuityMetric.answersCorrect.failing(
                    rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            let answer = subject.value.finalAnswer
            return expected.expectedKeyPhrases.allSatisfy { answer.localizedCaseInsensitiveContains($0) }
                ? CompactionContinuityMetric.answersCorrect.passing(rationale: "every planted fact survived the task")
                : CompactionContinuityMetric.answersCorrect.failing(rationale: answer)
        }
        Evaluator<Sample> { _, subject in
            subject.value.foldCount >= 1
                ? CompactionContinuityMetric.foldOccurred.passing(rationale: "\(subject.value.foldCount) fold(s) ran")
                : CompactionContinuityMetric.foldOccurred.failing(
                    rationale: "no fold ran while driving this task's steps")
        }
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionContinuityMetric.factsSurvived.failing(
                    rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            let answer = subject.value.finalAnswer
            return expected.factKeyPhrases.contains { answer.localizedCaseInsensitiveContains($0) }
                ? CompactionContinuityMetric.factsSurvived.passing(rationale: "at least one planted fact survived")
                : CompactionContinuityMetric.factsSurvived.failing(rationale: answer)
        }
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionContinuityMetric.budgetHeld.failing(rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            return subject.value.tokensAfter <= expected.targetTokens
                ? CompactionContinuityMetric.budgetHeld.passing()
                : CompactionContinuityMetric.budgetHeld.failing(
                    rationale: "tokensAfter \(subject.value.tokensAfter) > target \(expected.targetTokens)")
        }
        Evaluator<Sample> { sample, subject in
            guard let expected = sample.expected else {
                return CompactionContinuityMetric.recordingComplete.failing(
                    rationale: Self.sampleCarriedNoExpectedValueMessage)
            }
            return subject.value.recordedEntryCount >= expected.expectedMinimumRecordedEntries
                ? CompactionContinuityMetric.recordingComplete.passing()
                : CompactionContinuityMetric.recordingComplete.failing(
                    rationale:
                        "recordedEntryCount \(subject.value.recordedEntryCount) < expected minimum \(expected.expectedMinimumRecordedEntries)"
                )
        }
    }

    /// Registers all five metrics — `AnswersCorrect`, `FoldOccurred`,
    /// `FactsSurvived`, `BudgetHeld`, `RecordingComplete` — for mean
    /// aggregation, as the `Evaluation` protocol requires.
    ///
    /// - Parameter aggregator: The aggregator to register the five metrics
    ///   with.
    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: CompactionContinuityMetric.answersCorrect)
        aggregator.computeMean(of: CompactionContinuityMetric.foldOccurred)
        aggregator.computeMean(of: CompactionContinuityMetric.factsSurvived)
        aggregator.computeMean(of: CompactionContinuityMetric.budgetHeld)
        aggregator.computeMean(of: CompactionContinuityMetric.recordingComplete)
    }
}
