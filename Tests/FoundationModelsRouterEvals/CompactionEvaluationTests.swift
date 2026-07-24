import Evaluations
import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

// MARK: - Gate

/// The same opt-in environment variable every other gated real-model suite in
/// this repository checks (`FoundationModelsRouterIntegrationTests`'s own
/// `integrationEnvVar`) — unset (the default, and on any network/GPU-less
/// box, including this sandbox) the gated eval below is skipped, so
/// `swift test` stays green with no real model download or inference.
private let compactionEvalsIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var compactionEvalsIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionEvalsIntegrationEnvVar] != nil
}

// MARK: - Hermetic wiring (plain `swift test`, no real inference)

/// Hermetic proof that the evals target's wiring is correct: the dataset
/// loads every hand-written fixture, `subject(from:)` runs against a fake
/// model with no real inference, and pointing the same evaluation at two
/// different `CompactionPrompt`s yields per-prompt attributable outcomes —
/// exactly the acceptance criteria that do not need a real model to verify.
@Suite("CompactionEvaluation hermetic wiring")
struct CompactionEvaluationHermeticTests {
    @Test("the dataset loads at least 20 hand-written seed samples")
    func datasetLoadsAtLeast20Samples() async throws {
        let evaluation = CompactionEvaluation { _, _, _, _ in
            ("unused", 0, 0, [])
        }

        var count = 0
        for try await _ in evaluation.dataset.stream {
            count += 1
        }
        #expect(count >= 20)
        #expect(compactionEvalSeeds.count >= 20)
    }

    @Test("subject(from:) wires up against a fake model with no real inference")
    func subjectWiresUpAgainstFakeModel() async throws {
        nonisolated(unsafe) var capturedEntries: [Transcript.Entry] = []
        nonisolated(unsafe) var capturedQuestion = ""

        let evaluation = CompactionEvaluation { entries, _, _, question in
            capturedEntries = entries
            capturedQuestion = question
            // A canned, non-inferred response — proves the wiring, not any
            // real model's ability to answer.
            return ("the fake answer", 500, 50, ["ToolOutputElision", "TurnTruncation", "Summarization"])
        }

        var samples: [ModelSample<CompactionEvaluationOutcome>] = []
        for try await sample in evaluation.dataset.stream {
            samples.append(sample)
        }
        let sample = try #require(samples.first)
        let expected = try #require(sample.expected)
        let seed = try #require(compactionEvalSeeds.first { $0.id == expected.seedID })

        let subject = try await evaluation.subject(from: sample)

        #expect(subject.value.answer == "the fake answer")
        #expect(subject.value.tokensBefore == 500)
        #expect(subject.value.tokensAfter == 50)
        #expect(subject.value.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"])
        #expect(subject.value.plantedFact == expected.plantedFact)
        #expect(subject.value.factKeyPhrase == expected.factKeyPhrase)
        #expect(!capturedEntries.isEmpty)
        #expect(capturedQuestion == seed.question)
    }

    @Test(
        "the default budget forces the model-assisted Summarization stage for every fixture, not just ToolOutputElision/TurnTruncation"
    )
    func defaultBudgetForcesSummarizationStage() async throws {
        // A hermetic proof of `CompactionEvaluation.init`'s own claim: the
        // default budget's target is small enough that the untouched
        // recency window alone still exceeds it, so `Compactor.compact`
        // always falls through past the two deterministic stages into
        // `Summarization` — never stopping at `TurnTruncation`, which would
        // drop the planted fact with no trace at all (no summary entry to
        // check `FactRetention` against). Uses the real `Compactor` pipeline
        // directly (not `CompactionEvaluation`) with a trivial fake
        // summarizer — still no real inference.
        struct FakeSummarizer: CompactionSummarizer {
            func summarize(_ prompt: String) async throws -> String { "fake summary" }
        }

        let budget = TokenBudget(limit: 4000, trigger: 0.80, target: 0.05)
        for seed in compactionEvalSeeds {
            let (_, result) = try await Compactor.compact(
                Transcript(entries: seed.entries),
                budget: budget,
                summarizer: FakeSummarizer()
            )
            #expect(
                result.stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"],
                "seed \(seed.id) did not reach Summarization: stagesApplied was \(result.stagesApplied)"
            )
        }
    }

    @Test("running the evaluation with two different prompt names yields per-prompt attributable outcomes")
    func differentPromptNamesAreAttributable() async throws {
        let promptA = CompactionPrompt(name: "eval-hermetic-candidate-a", text: "Summarize as A.")
        let promptB = CompactionPrompt(name: "eval-hermetic-candidate-b", text: "Summarize as B.")

        let evaluationA = CompactionEvaluation(prompt: promptA) { _, prompt, _, _ in (prompt.name, 0, 0, []) }
        let evaluationB = CompactionEvaluation(prompt: promptB) { _, prompt, _, _ in (prompt.name, 0, 0, []) }

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
        #expect(subjectA.value.answer == promptA.name)
        #expect(subjectB.value.answer == promptB.name)
    }

    private static func firstSample(
        of evaluation: CompactionEvaluation
    ) async throws -> ModelSample<CompactionEvaluationOutcome>? {
        for try await sample in evaluation.dataset.stream {
            return sample
        }
        return nil
    }
}

// MARK: - Gated real-model eval

/// Loads ``CompactionEvalRealModel`` at most once for the gated `@Test`
/// below — declared at file scope (not a suite member) so it can be
/// referenced directly from the `.evaluates(...)` trait argument, which is
/// evaluated synchronously when the test is registered, long before this
/// runner's own model load (deferred to its first `run(entries:prompt:budget:question:)`
/// call, well inside the async `run()` the trait drives).
private let compactionEvalRealSubjectRunner = CompactionEvalRealSubjectRunner()

/// The gated evaluation itself: points at every hand-written fixture with the
/// router's default compaction prompt, folding against a budget whose target
/// is small enough to force the model-assisted `Summarization` stage (see
/// ``CompactionEvaluation/init(prompt:budget:seeds:runSubject:)``'s own doc
/// comment).
private let compactionEvalRealEvaluation = CompactionEvaluation { entries, prompt, budget, question in
    try await compactionEvalRealSubjectRunner.run(entries: entries, prompt: prompt, budget: budget, question: question)
}

/// The gated real-model eval (compaction_plan.md §5's `@Test(.evaluates(...))`
/// sketch): folds every hand-written seed transcript with the router's
/// default compaction prompt, resumes a session over each result, asks its
/// question, and asserts mean `FactRetention` across the whole dataset is at
/// least 0.9.
///
/// Runtime-gated on `FM_ROUTER_INTEGRATION_TESTS`, exactly like every other
/// real-model suite in this repository — never runs on a network/GPU-less
/// box (including this task's authoring sandbox: real model inference is
/// unavailable here, the same documented limitation every other gated suite
/// in `FoundationModelsRouterIntegrationTests` already carries). The target
/// itself, and this file's hermetic tests above, always build and run.
@Suite(.enabled(if: compactionEvalsIntegrationEnabled))
struct CompactionEvaluationIntegrationTests {
    @Test(
        "Compaction retains pre-fold facts",
        .evaluates(
            compactionEvalRealEvaluation,
            info: ["promptName": CompactionPrompt.default.name]
        )
    )
    func evaluateCompaction() async throws {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= 0.9)
        await compactionEvalRealSubjectRunner.evictIfLoaded()
    }
}
