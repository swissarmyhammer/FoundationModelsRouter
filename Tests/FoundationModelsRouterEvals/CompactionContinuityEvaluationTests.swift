import Evaluations
import Foundation
import Testing

@testable import FoundationModelsRouter

// MARK: - Gate

/// The same opt-in environment variable every other gated real-model suite in
/// this repository checks — see ``compactionEvalsIntegrationEnvVar``'s own
/// doc comment. Unset (the default, and on any network/GPU-less box,
/// including this sandbox) the gated eval below is skipped, so `swift test`
/// stays green with no real model download or inference.
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
        // A mechanical proxy for "sized to be impossible without >=1 fold"
        // (task 4ce0a1k): every fixture's own `fillerStepCount` pads the
        // task well past a handful of turns — the same order of magnitude
        // `CompactionRoundTripIntegrationTests`'s own scripted turns use to
        // reliably cross a small budget's trigger — so no fixture accidentally
        // ships too small to ever force a fold once actually driven through
        // a live session.
        for spec in compactionContinuityTaskSpecs {
            #expect(spec.fillerStepCount >= 8, "task \(spec.id) has too few filler steps to reliably force a fold")
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
/// box (including this task's authoring sandbox: real model inference is
/// unavailable here, the same documented limitation every other gated suite
/// in this repository already carries). The target itself, and this file's
/// hermetic tests above, always build and run.
@Suite(.enabled(if: compactionContinuityIntegrationEnabled))
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
        await compactionContinuityEvalRealSubjectRunner.evictIfLoaded()
    }
}
