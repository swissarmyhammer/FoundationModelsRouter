import Evaluations
import Foundation
import Testing

@testable import FoundationModelsRouter

// MARK: - Gate

/// The same opt-in environment variable every other gated real-model suite in
/// this repository checks — see ``compactionEvalsIntegrationEnvVar``'s own
/// doc comment. Unset (the default, and on any network/GPU-less box) the
/// gated eval below is skipped, so `swift test` stays green with no real
/// model download or inference.
private let compactionContinuityIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var compactionContinuityIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionContinuityIntegrationEnvVar] != nil
}

// MARK: - Hermetic wiring (plain `swift test`, no real inference)

/// Hermetic proof that ``CompactionContinuityEvaluation``'s wiring is
/// correct: the dataset loads every hand-written task, `subject(from:)` runs
/// against a fake closure with no real inference, and pointing the same
/// evaluation at two different `CompactionPrompt`s yields per-prompt
/// attributable outcomes — mirrors ``CompactionEvaluationHermeticTests``.
@Suite("CompactionContinuityEvaluation hermetic wiring")
struct CompactionContinuityEvaluationHermeticTests {
    @Test("the dataset loads at least 5 hand-written task samples")
    func datasetLoadsAtLeast5Samples() async throws {
        let evaluation = CompactionContinuityEvaluation { _, _, _, _ in
            ("unused", 0, 0, 0, 0, "unused-model")
        }

        var count = 0
        for try await _ in evaluation.dataset.stream {
            count += 1
        }
        #expect(count >= 5)
        #expect(compactionContinuitySeeds.count >= 5)
    }

    @Test("every hand-written task is sized so its filler steps alone exceed the default budget's trigger threshold")
    func everyTaskIsSizedToForceAFold() async throws {
        // The mechanical proof of "sized to be impossible without >=1 fold"
        // (task 4ce0a1k), measured in the same tokens the live trigger is
        // measured in: every fixture's filler steps, on their own, estimate to
        // more than `compactionContinuityDefaultBudget.triggerTokens`. A live
        // session's transcript also carries the setup steps, the final
        // instruction, and every reply, so the real conversation crosses the
        // trigger strictly sooner than this — filler alone is the conservative
        // bound.
        //
        // This deliberately does not assert `fillerStepCount`. A step *count*
        // says nothing about token size, and asserting one let this dataset
        // ship roughly 8x too small to ever reach the trigger while the test
        // stayed green (task 5m97h14).
        let triggerTokens = compactionContinuityDefaultBudget.triggerTokens
        for seed in compactionContinuitySeeds {
            let spec = try #require(compactionContinuityTaskSpecs.first { $0.id == seed.id })
            let fillerSteps = seed.steps.suffix(spec.fillerStepCount)
            let fillerTokens = Compactor.estimatedTokenCount(of: fillerSteps.joined(separator: "\n"))
            #expect(
                fillerTokens > triggerTokens,
                "task \(seed.id)'s \(spec.fillerStepCount) filler steps estimate \(fillerTokens) tokens, which does not exceed the trigger's \(triggerTokens)"
            )
        }
    }

    @Test("subject(from:) wires up against a fake model with no real inference")
    func subjectWiresUpAgainstFakeModel() async throws {
        // Safe: this closure runs exactly once, synchronously within the
        // single `await evaluation.subject(from: sample)` call below, on
        // this test's own task — never from a spawned/concurrent task —
        // and both vars are read only after that await returns, so there
        // is never a concurrent access despite crossing the `@Sendable`
        // closure boundary. Mirrors `CompactionEvaluationHermeticTests.subjectWiresUpAgainstFakeModel`.
        nonisolated(unsafe) var capturedSteps: [String] = []
        nonisolated(unsafe) var capturedFinalInstruction = ""

        let evaluation = CompactionContinuityEvaluation { steps, finalInstruction, _, _ in
            capturedSteps = steps
            capturedFinalInstruction = finalInstruction
            // A canned, non-inferred response — proves the wiring, not any
            // real model's ability to answer.
            return ("the fake final answer", 2, 500, 50, 12, "fake-model")
        }

        var samples: [ModelSample<CompactionContinuityOutcome>] = []
        for try await sample in evaluation.dataset.stream {
            samples.append(sample)
        }
        let sample = try #require(samples.first)
        let expected = try #require(sample.expected)
        let task = try #require(compactionContinuitySeeds.first { $0.id == expected.taskID })

        let subject = try await evaluation.subject(from: sample)

        #expect(subject.value.finalAnswer == "the fake final answer")
        #expect(subject.value.foldCount == 2)
        #expect(subject.value.tokensBefore == 500)
        #expect(subject.value.tokensAfter == 50)
        #expect(subject.value.recordedEntryCount == 12)
        #expect(subject.value.modelName == "fake-model")
        #expect(subject.value.factKeyPhrases == expected.factKeyPhrases)
        #expect(subject.value.expectedKeyPhrases == expected.expectedKeyPhrases)
        #expect(capturedSteps == task.steps)
        #expect(capturedFinalInstruction == task.finalInstruction)
    }

    @Test("running the evaluation with two different prompt names yields per-prompt attributable outcomes")
    func differentPromptNamesAreAttributable() async throws {
        let promptA = CompactionPrompt(name: "continuity-hermetic-candidate-a", text: "Summarize as A.")
        let promptB = CompactionPrompt(name: "continuity-hermetic-candidate-b", text: "Summarize as B.")

        let evaluationA = CompactionContinuityEvaluation(prompt: promptA) { _, _, prompt, _ in
            (prompt.name, 1, 0, 0, 0, "model")
        }
        let evaluationB = CompactionContinuityEvaluation(prompt: promptB) { _, _, prompt, _ in
            (prompt.name, 1, 0, 0, 0, "model")
        }

        let sampleA = try #require(try await Self.firstSample(of: evaluationA))
        let sampleB = try #require(try await Self.firstSample(of: evaluationB))

        // The dataset itself stamps every sample's ground truth with the
        // evaluation's own prompt name — attributable before any subject
        // even runs.
        #expect(sampleA.expected?.promptName == promptA.name)
        #expect(sampleB.expected?.promptName == promptB.name)

        let subjectA = try await evaluationA.subject(from: sampleA)
        let subjectB = try await evaluationB.subject(from: sampleB)

        // The produced outcome is also attributable, and the two prompts'
        // results are distinguishable from one another.
        #expect(subjectA.value.promptName == promptA.name)
        #expect(subjectB.value.promptName == promptB.name)
        #expect(subjectA.value.promptName != subjectB.value.promptName)
        #expect(subjectA.value.finalAnswer == promptA.name)
        #expect(subjectB.value.finalAnswer == promptB.name)
    }

    // MARK: - Evaluator mechanics

    @Test("AnswersCorrect requires every expected key phrase; FactsSurvived requires only one")
    func answersCorrectIsStrictFactsSurvivedIsLenient() async throws {
        // Two facts required for a fully correct answer; the fake subject
        // below only echoes one of them — proving AnswersCorrect (needs
        // both) and FactsSurvived (needs only one) diverge exactly as
        // documented, not just coincidentally agree.
        let task = try #require(compactionContinuitySeeds.first { $0.factKeyPhrases.count >= 2 })
        let onlyFirstFact = try #require(task.factKeyPhrases.first)

        let evaluation = CompactionContinuityEvaluation(tasks: [task]) { _, _, _, _ in
            ("the answer mentions \(onlyFirstFact) but nothing else", 1, 0, 0, 0, "model")
        }

        let sample = try #require(try await Self.firstSample(of: evaluation))
        let subject = try await evaluation.subject(from: sample)

        var allMetrics: [Metric] = []
        for evaluator in evaluation.evaluators {
            allMetrics += try await evaluator.metrics(subject: subject, input: sample)
        }

        let answersCorrect = try #require(allMetrics[CompactionContinuityMetric.answersCorrect])
        let factsSurvived = try #require(allMetrics[CompactionContinuityMetric.factsSurvived])
        #expect(answersCorrect.value == .failing)
        #expect(factsSurvived.value == .passing)
    }

    @Test("BudgetHeld and RecordingComplete are mechanical threshold checks against the produced outcome")
    func budgetHeldAndRecordingCompleteAreThresholdChecks() async throws {
        let task = try #require(compactionContinuitySeeds.first)

        let underBudgetEvaluation = CompactionContinuityEvaluation(
            budget: TokenBudget(limit: 1000, trigger: 0.80, target: 0.10), tasks: [task]
        ) { _, _, _, _ in
            ("answer", 1, 500, 50, task.expectedMinimumRecordedEntries, "model")
        }
        let underBudgetSample = try #require(try await Self.firstSample(of: underBudgetEvaluation))
        let underBudgetSubject = try await underBudgetEvaluation.subject(from: underBudgetSample)
        #expect(underBudgetSubject.value.tokensAfter <= underBudgetSubject.value.targetTokens)

        let overBudgetEvaluation = CompactionContinuityEvaluation(
            budget: TokenBudget(limit: 1000, trigger: 0.80, target: 0.10), tasks: [task]
        ) { _, _, _, _ in
            ("answer", 1, 500, 999, task.expectedMinimumRecordedEntries - 1, "model")
        }
        let overBudgetSample = try #require(try await Self.firstSample(of: overBudgetEvaluation))
        let overBudgetSubject = try await overBudgetEvaluation.subject(from: overBudgetSample)
        #expect(overBudgetSubject.value.tokensAfter > overBudgetSubject.value.targetTokens)
        #expect(overBudgetSubject.value.recordedEntryCount < overBudgetSubject.value.expectedMinimumRecordedEntries)
    }

    private static func firstSample(
        of evaluation: CompactionContinuityEvaluation
    ) async throws -> ModelSample<CompactionContinuityOutcome>? {
        for try await sample in evaluation.dataset.stream {
            return sample
        }
        return nil
    }
}

// MARK: - Hermetic progress-line rendering

/// Hermetic proof that the continuity tier leaves a live trail naming where a
/// run stopped (task ^aktsp2e).
///
/// This tier costs 20 minutes against a 30B model and used to print nothing at
/// all until it ended, so a run that hit its own limit reported one bit — "not
/// finished" — and no reading of its output could say whether the model load,
/// one of a task's dozen-odd steps, or the final instruction had spent the time.
///
/// These tests pin the lines that answer that question, and they pin the one
/// property the two tiers share: ``CompactionEvalProgressLog/linePrefix`` and
/// ``CompactionEvalProgressLog/makeSecondsText(_:)`` are the same for both, so
/// one `grep` reads either trail.
@Suite("CompactionContinuityEvaluation progress lines")
struct CompactionContinuityEvalProgressLogTests {
    /// Where in its tier the sample ``label`` names stands — the middle, so a
    /// rendered ordinal that silently used the total (or the reverse) shows.
    private static let sampleOrdinal = 2

    /// How many tasks the tier ``label`` names states.
    private static let tierTaskCount = compactionContinuitySeeds.count

    /// The task id ``label`` names.
    private static let sampleTaskID = "probe-task"

    /// A sample label in the middle of its tier.
    private static let label = CompactionEvalSampleLabel(
        ordinal: sampleOrdinal, total: tierTaskCount, fixture: .task, fixtureID: sampleTaskID)

    /// Where in its task the step these tests render stands — again the middle.
    private static let stepOrdinal = 4

    /// How many steps the task these tests render drives.
    private static let taskStepCount = 13

    /// A duration with a fractional part the rendering must keep.
    private static let stepSeconds = 41.62

    /// The sample's elapsed total at the point a step returned.
    private static let elapsedSeconds = 173.45

    @Test("a continuity line names the task, not a seed, and states its position in the tier")
    func continuityLineNamesTheTaskAndItsPositionInTheTier() {
        let line = CompactionEvalProgressLog.makeStepStartedLine(
            .step,
            sample: Self.label,
            elapsedSeconds: Self.elapsedSeconds,
            detail: CompactionEvalProgressLog.makeStepPositionDetail(
                ordinal: Self.stepOrdinal, of: Self.taskStepCount)
        )

        #expect(line.contains("sample=\(Self.sampleOrdinal)/\(Self.tierTaskCount)"))
        #expect(line.contains("task=\(Self.sampleTaskID)"))
        // The fact-retention tier's own key, which this tier must not borrow.
        #expect(!line.contains("seed="))
    }

    @Test("a step's started line names which step of the task it is, so a hung run says where it stopped")
    func stepStartedLineNamesWhichStepOfTheTask() {
        let line = CompactionEvalProgressLog.makeStepStartedLine(
            .step,
            sample: Self.label,
            elapsedSeconds: Self.elapsedSeconds,
            detail: CompactionEvalProgressLog.makeStepPositionDetail(
                ordinal: Self.stepOrdinal, of: Self.taskStepCount)
        )

        #expect(line.contains("step=\(Self.stepOrdinal)/\(Self.taskStepCount)"))
        #expect(line.contains("elapsed=\(CompactionEvalProgressLog.makeSecondsText(Self.elapsedSeconds))"))
        // The step has not finished, so it has no duration of its own yet.
        #expect(!line.contains("took="))
    }

    @Test("a sample's first step states no elapsed clause, rather than a zero that reads as a measurement")
    func firstStepOfASampleStatesNoElapsedClause() {
        let first = CompactionEvalProgressLog.makeStepStartedLine(
            .step,
            sample: Self.label,
            elapsedSeconds: nil,
            detail: CompactionEvalProgressLog.makeStepPositionDetail(ordinal: 1, of: Self.taskStepCount)
        )

        #expect(!first.contains("elapsed="))
        // The position is still stated, so the line still names where it is.
        #expect(first.contains("step=1/\(Self.taskStepCount)"))
    }

    @Test("a driven step's returned line states its reply size and whether it folded")
    func drivenStepReturnedLineStatesItsReplyAndItsFolds() {
        let reply = "Understood."
        let foldedDetail = CompactionEvalProgressLog.makeDrivenStepDetail(reply: reply, foldCount: 1)
        let unfoldedDetail = CompactionEvalProgressLog.makeDrivenStepDetail(reply: reply, foldCount: 0)

        #expect(foldedDetail.contains("replyBytes=\(reply.utf8.count)"))
        // The fold count is what this tier exists to watch: the trail must say
        // which step folded, not merely that some step did.
        #expect(foldedDetail.contains("folds=1"))
        #expect(unfoldedDetail.contains("folds=0"))
    }

    @Test("the final instruction is a step of its own, with its own duration")
    func finalInstructionIsAStepOfItsOwn() {
        let line = CompactionEvalProgressLog.makeStepReturnedLine(
            .finalInstruction,
            sample: Self.label,
            elapsedSeconds: Self.elapsedSeconds,
            stepSeconds: Self.stepSeconds,
            detail: CompactionEvalProgressLog.makeDrivenStepDetail(reply: "CRIMSON-77 at Delta-9.", foldCount: 0)
        )

        #expect(
            line.contains(
                "\(CompactionEvalProgressStep.finalInstruction.rawValue) "
                    + "\(CompactionEvalProgressLog.returnedMarker)"))
        #expect(line.contains("took=\(CompactionEvalProgressLog.makeSecondsText(Self.stepSeconds))"))
        #expect(line.contains("elapsed=\(CompactionEvalProgressLog.makeSecondsText(Self.elapsedSeconds))"))
    }

    @Test("both gated tiers share one line prefix and one seconds rendering, so one grep reads either")
    func bothTiersShareOnePrefixAndOneSecondsRendering() {
        let factRetentionLine = CompactionEvalProgressLog.makeStepReturnedLine(
            .fold,
            sample: CompactionEvalSampleLabel(
                ordinal: 1, total: 1, fixture: .seed, fixtureID: "probe-seed"),
            elapsedSeconds: Self.elapsedSeconds,
            stepSeconds: Self.stepSeconds,
            detail: ""
        )
        let continuityLine = CompactionEvalProgressLog.makeStepReturnedLine(
            .step,
            sample: Self.label,
            elapsedSeconds: Self.elapsedSeconds,
            stepSeconds: Self.stepSeconds,
            detail: ""
        )

        for line in [factRetentionLine, continuityLine] {
            #expect(line.hasPrefix(CompactionEvalProgressLog.linePrefix))
            #expect(line.contains("took=\(CompactionEvalProgressLog.makeSecondsText(Self.stepSeconds))"))
        }
    }

    @Test("every task's final instruction resolves to that task, so no line can mislabel the sample it names")
    func everyTasksFinalInstructionResolvesToThatTask() {
        // Asserted through the RENDERED label rather than through the keyed
        // dictionary. The dictionary is a means; what a run cut short leaves
        // behind is the line, so the line is what has to name the right task. A
        // join that dropped a task renders
        // `CompactionEvalFactRetentionReport.unmatchedSeedID` here and fails.
        let tasks = compactionContinuitySeeds
        let keyed = CompactionContinuitySeed.keyedByFinalInstruction(tasks)

        for (offset, task) in tasks.enumerated() {
            let ordinal = offset + 1
            let label = CompactionEvalSampleLabel(
                ordinal: ordinal,
                of: tasks.count,
                fixture: .task,
                id: keyed[task.finalInstruction]?.id
            )

            #expect(label.rendered.contains("task=\(task.id)"))
            #expect(label.rendered.contains("sample=\(ordinal)/\(tasks.count)"))
        }
    }

    @Test("a label whose final instruction matches no task is still named, by the report's own marker")
    func labelWhoseFinalInstructionMatchesNoTaskIsStillNamed() {
        let tasks = compactionContinuitySeeds
        let label = CompactionEvalSampleLabel(
            ordinal: 1,
            of: tasks.count,
            fixture: .task,
            id: CompactionContinuitySeed.keyedByFinalInstruction(tasks)["an instruction no task asks"]?.id
        )

        #expect(label.fixtureID == CompactionEvalFactRetentionReport.unmatchedSeedID)
    }
}

// MARK: - Gated real-model eval

/// Loads ``CompactionContinuityEvalRealSubjectRunner`` at most once for the
/// gated `@Test` below — declared at file scope for the same reason
/// `compactionEvalRealSubjectRunner` is: it must be referenceable from the
/// synchronously-evaluated `.evaluates(...)` trait argument.
private let compactionContinuityEvalRealSubjectRunner = CompactionContinuityEvalRealSubjectRunner()

/// The gated evaluation itself: points at every hand-written multi-step
/// task with the router's default compaction prompt, driving each through a
/// real, auto-compacting session.
private let compactionContinuityEvalRealEvaluation = CompactionContinuityEvaluation { steps, finalInstruction, prompt, budget in
    try await compactionContinuityEvalRealSubjectRunner.run(
        steps: steps, finalInstruction: finalInstruction, prompt: prompt, budget: budget)
}

/// The gated real-model eval (task 4ce0a1k): drives every hand-written
/// multi-step task through a real, auto-compacting session and asserts mean
/// `AnswersCorrect` and `FoldOccurred` across the whole dataset meet their
/// thresholds.
///
/// Runtime-gated on `FM_ROUTER_INTEGRATION_TESTS`, exactly like every other
/// real-model suite in this repository — never runs on a network/GPU-less
/// box. The target itself, and this file's hermetic tests above, always build
/// and run.
///
/// This suite was long described here as blocked by an MLX `default.metallib`
/// load failure that no gated suite in this repository could get past. That
/// was wrong: the failure was a resource-colocation bug in `swift test`'s
/// binary layout, which ``MetalLibraryTestBootstrap`` now fixes from inside
/// ``GatedEvalResidencyTrait``, this suite's own trait.
///
/// ``GatedEvalResidencyTrait`` holds this suite's real model exclusive against
/// the other gated eval suite and evicts it when the suite ends, and
/// ``gatedEvalSuiteTimeLimitMinutes`` bounds a hung real-model load — see
/// ``GatedEvalSerialGate`` for why the target needs both.
@Suite(
    .enabled(if: compactionContinuityIntegrationEnabled),
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
