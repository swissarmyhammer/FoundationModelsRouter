import Evaluations

import FoundationModelsRouter

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
    // Only `CompactionContinuityEvalRealSubjectRunner`, in the
    // IntegrationTests package, uses this case. Periphery reads only this
    // package's index, thus it finds no user.
    // periphery:ignore
    case unexpectedContainerType
}

/// The auto-compaction budget every ``CompactionContinuityEvaluation`` vends
/// its sessions with unless a caller passes its own.
///
/// `limit` is deliberately far below any real model's working context: the
/// point of this evaluation is that a *multi-step task* forces at least one
/// live fold partway through, and a small limit is what makes that happen
/// within a dozen-odd turns instead of hundreds. Since ``TokenBudget/trigger``
/// resolves against this `limit` rather than against the session's own resolved
/// window (see ``TokenBudget/triggerTokens``), the trigger fires at 1638 real
/// tokens however large the model's window is — which is exactly the property
/// `CompactionContinuityEvaluationTests.everyTaskIsSizedToForceAFold` sizes the
/// fixtures against.
///
/// `target` leaves the folded window at 30% of the limit, well clear of the
/// four-turn recency window no deterministic stage may touch, so a fold has
/// somewhere to land.
let compactionContinuityDefaultBudget = TokenBudget(limit: 2048, trigger: 0.80, target: 0.30)

/// Where the FAST continuity tier puts the auto-compaction trigger, as a share
/// of ``CompactionContinuityRealModel/context``.
///
/// This is `AutoCompactionTriggerIntegrationTests`' proven device, applied to
/// the continuity tier for task ^k0d30s4's two-minute budget. The number is
/// chosen to be far under anything a fixture could be sized against: it
/// resolves to 164 tokens of the 8192-token window, and the fast tier's
/// opening step alone measures several hundred real tokens, so the trigger is
/// crossed by construction rather than by arithmetic over the fixture.
/// `CompactionContinuityEvaluationHermeticTests` still holds the crossing
/// with a conservative conversion, so a shrunken padding paragraph goes red
/// on a plain `swift test` rather than in a gated run.
let compactionContinuityFastTriggerShareOfContext = 0.02

/// Where the fast tier puts the fold target, as a share of
/// ``CompactionContinuityRealModel/context``.
///
/// It resolves to 492 estimated tokens. Two properties place it:
///
/// - The opening step alone estimates past it, so `Compactor.compact`'s own
///   entry guard (`tokensBefore > targetTokens`) passes when the fold fires.
/// - The deterministic stages can never land it. A fast task holds three
///   turns, fewer than ``TurnTruncation``'s default window of four, so
///   truncation drops nothing and the pipeline always falls through to the
///   model-assisted ``Summarization`` stage — the stage whose summary the
///   tier measures. That guarantee is structural (a turn count against a
///   window), not an estimate against a size, which is the arithmetic task
///   ^wnj3ka3 showed drifting.
///
/// The folded transcript — one summary entry, the readiness turn, and the
/// header — lands well under this target, so ``CompactionContinuityMetric/budgetHeld``
/// stays a real measurement rather than a constant failure.
let compactionContinuityFastTargetShareOfContext = 0.06

/// The auto-compaction budget the FAST continuity tier vends its sessions
/// with.
///
/// `limit` is ``CompactionContinuityRealModel/context`` and not a number of
/// its own, so the session's measured context fill and the budget's trigger
/// stay on one scale — ``TokenBudget/triggerTokens`` states that a budget
/// whose limit differs from the session's window has its trigger silently
/// scaled by the ratio between the two.
let compactionContinuityFastBudget = TokenBudget(
    limit: CompactionContinuityRealModel.context,
    trigger: compactionContinuityFastTriggerShareOfContext,
    target: compactionContinuityFastTargetShareOfContext
)

/// How many of the newest turns every fast-tier fold leaves untouched.
///
/// One is what lets a THREE-turn task fold: ``Summarization`` answers `nil`
/// while every turn is inside the recency window, and at the default of four
/// a fast task would need five turns — five real generations — before a fold
/// could do anything. One is also the smallest window that is still a window:
/// the fold replaces the opening turn and keeps the readiness turn verbatim.
/// `AutoCompactionTriggerIntegrationTests` uses the same value for the same
/// reason.
let compactionContinuityFastKeepRecentTurns = 1

/// The model-assisted stage the fast continuity tier vends its sessions with.
///
/// A session is where this choice belongs, because an automatic fold has no
/// caller to pass one to. See ``compactionContinuityFastKeepRecentTurns`` for
/// the recency window and ``compactionEvalReasoningTokenHeadroom`` for the
/// generation bound both gated tiers share.
// Only `CompactionContinuityRealModelTests`, in the IntegrationTests
// package, reads this. Periphery reads only this package's index, thus it
// finds no reader — and thus also none for the two constants the body
// below reads.
// periphery:ignore
var compactionContinuityFastSummarization: Summarization {
    Summarization(
        keepRecentTurns: compactionContinuityFastKeepRecentTurns,
        reasoningTokenHeadroom: compactionEvalReasoningTokenHeadroom
    )
}

/// The mean `FactsSurvived` the gated continuity tier must reach: at least
/// one planted fact in the final answer, after a real fold.
///
/// The subject's measured baseline, minus one task of margin — the standing
/// rule every gated eval floor follows. The gated run of 2026-08-21 under
/// ``CompactionContinuityRealModel`` (Qwen2.5-3B-Instruct), at greedy
/// decoding, under task ^xx02yn6's `router-default-v3` prompt, over the four
/// tasks ``compactionContinuityFastTierIDs`` names, measured 4 of 4 tasks
/// carrying at least one fact end to end, and the four fold summaries carried
/// both facts verbatim. One task under that is 3 of 4, which is 0.75. Written
/// as 0.7, which sits under 3/4 and over 2/4, so the tier must keep exactly
/// those 3: a second lost task moves the mean by a quarter, which no rounding
/// hides. Greedy decoding makes the score a fact about the prompt and the
/// fixtures rather than a draw, so a floor one task under the baseline holds
/// the measured behavior while absorbing one cross-machine flip. A
/// compaction-prompt regression that loses the facts from the summaries
/// crashes this floor, which is the regression the tier exists to catch.
///
/// The 0.6 this value stated before task ^mx4jqrn was the same rule over the
/// 1B Llama canary's 7 of 10 tasks on 2026-08-19. Task ^xx02yn6's prompt
/// redesign then took that model to 1 of 10, which is why the tier changed
/// its subject rather than its floor — see ``CompactionContinuityRealModel``.
// Only `CompactionContinuityRealModelTests`, in the IntegrationTests
// package, reads this. Periphery reads only this package's index, thus it
// finds no reader.
// periphery:ignore
let compactionContinuityFastFactsSurvivedFloor = 0.7

/// The mean `AnswersCorrect` the gated continuity tier must reach: BOTH
/// planted facts in the final answer, word for word, after a real fold.
///
/// The subject's measured baseline, minus one task of margin, exactly as
/// ``compactionContinuityFastFactsSurvivedFloor`` is derived: the gated run
/// of 2026-08-21 under Qwen2.5-3B-Instruct, over the same four tasks,
/// measured 3 of 4. The one miss was `migration-script-and-rollback`, whose
/// fold summary carried both paths verbatim and whose answering turn wrote
/// `rollback_2266_07` for `rollback_2026_07` — the answer's loss, not the
/// fold's. One task under 3 of 4 is 2 of 4, which is 0.5. Written as 0.45,
/// which sits under 2/4 and over 1/4, so the tier must answer exactly those 2.
/// The 0.8 bar the 30B tier held is NOT reachable by a small model whose
/// answering turn drops a digit from an identifier its own fold summary
/// carries verbatim, and a bar the subject cannot reach measures the model,
/// not the compaction prompt. The suite's doc comment states this trade in
/// full.
///
/// The 0.3 this value stated before task ^mx4jqrn was the same rule over the
/// 1B canary's 4 of 10 on 2026-08-19; that model measured 0 of 10 under the
/// redesigned prompt on 2026-08-20.
// Only `CompactionContinuityRealModelTests`, in the IntegrationTests
// package, reads this. Periphery reads only this package's index, thus it
// finds no reader.
// periphery:ignore
let compactionContinuityFastAnswersCorrectFloor = 0.45

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
    ///     drives is vended with. Defaults to
    ///     ``compactionContinuityDefaultBudget``, small enough that every
    ///     hand-written task (see ``compactionContinuityTaskSpecs``) forces at
    ///     least one live fold before its final instruction.
    ///   - tasks: The task fixtures to draw samples from. Defaults to
    ///     ``compactionContinuitySeeds`` (every hand-written fixture).
    ///   - runSubject: Runs one sample's subject work — see ``runSubject``.
    init(
        prompt: CompactionPrompt = .default,
        budget: TokenBudget = compactionContinuityDefaultBudget,
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
