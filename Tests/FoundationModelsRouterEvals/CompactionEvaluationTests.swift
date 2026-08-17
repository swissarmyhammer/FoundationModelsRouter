import Evaluations
import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

// MARK: - Gate

/// The same opt-in environment variable every other gated real-model suite in
/// this repository checks (`FoundationModelsRouterIntegrationTests`'s own
/// `integrationEnvVar`) — unset (the default, and on any network/GPU-less
/// box) the gated eval below is skipped, so `swift test` stays green with no
/// real model download or inference.
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
        // Safe: this closure runs exactly once, synchronously within the
        // single `await evaluation.subject(from: sample)` call below, on
        // this test's own task — never from a spawned/concurrent task —
        // and both vars are read only after that await returns, so there
        // is never a concurrent access despite crossing the `@Sendable`
        // closure boundary.
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
        // A hermetic proof of `compactionEvalDefaultBudget`'s own claim: its
        // target is small enough that the untouched recency window alone still
        // exceeds it, so `Compactor.compact` always falls through past the two
        // deterministic stages into `Summarization` — never stopping at
        // `TurnTruncation`, which would drop the planted fact with no trace at
        // all (no summary entry to check `FactRetention` against). Uses the
        // real `Compactor` pipeline directly (not `CompactionEvaluation`) with
        // a trivial fake summarizer — still no real inference.
        //
        // The budget is read from the same constant the evaluation itself
        // defaults to, never restated as a literal here: a copy would let the
        // two drift, and this assertion's whole job is to fail when the value
        // stops forcing `Summarization`.
        struct FakeSummarizer: CompactionSummarizer {
            func summarize(_ prompt: String, maxTokens: Int) async throws -> String { "fake summary" }
        }

        let budget = compactionEvalDefaultBudget
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

    @Test("no seed transcript repeats an assistant reply, so no recency window is saturated with one string")
    func noSeedRepeatsAnAssistantReply() {
        // The gated run of 2026-08-09 classified 18 of 19 `factRetention`
        // failures as `answerMissedFactSummaryCarriedIt`, and every one of the
        // 18 answered with the literal string `"Noted."` — which was, at the
        // time, the single canned reply every statement turn of every fixture
        // carried. `Summarization` keeps the newest turns verbatim, so each
        // resumed window ended in 4-7 consecutive `question -> "Noted."` pairs
        // and the model had a repeated pattern of its own visible transcript to
        // complete instead of a summary to read. A dataset that repeats one
        // reply cannot tell compaction quality apart from pattern completion,
        // so uniqueness is the property the fixtures must hold.
        for seed in compactionEvalSeeds {
            let replies = Self.assistantReplies(of: seed)
            #expect(!replies.isEmpty, "seed \(seed.id) built no assistant replies at all")
            #expect(
                Set(replies).count == replies.count,
                "seed \(seed.id) repeats an assistant reply: \(replies)"
            )
        }
    }

    /// Every assistant reply in `seed`'s built transcript, in order — the text
    /// content of each `.response` entry.
    ///
    /// - Parameter seed: The built seed to read.
    /// - Returns: The replies, in transcript order.
    private static func assistantReplies(of seed: CompactionEvalSeed) -> [String] {
        seed.entries.compactMap { entry -> String? in
            guard case .response(let response) = entry else { return nil }
            return
                response.segments
                .compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }
                .joined(separator: "\n")
        }
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

// MARK: - Hermetic fact-retention classification

/// Hermetic proof that ``CompactionEvalFactRetentionReport`` attributes a
/// failing `FactRetention` sample to the right side of the fold.
///
/// The gated eval's mean is one number over the whole dataset, so a run that
/// misses the bar says nothing about *where* each failing sample lost its
/// fact. These tests pin the three distinguishable places apart — the answer
/// lost a fact the summary carried, the fold itself dropped it, or no summary
/// was produced at all — so the gated run's attribution is a measurement over
/// every sample rather than an argument from a few of them.
@Suite("CompactionEvaluation fact-retention classification")
struct CompactionEvalFactRetentionReportTests {
    /// A seed whose `question` is the join key every test below records
    /// against.
    private static let seed = CompactionEvalSeed(
        id: "probe-seed",
        entries: [],
        plantedFact: "The project's internal vault code is CRIMSON-77.",
        factKeyPhrase: "CRIMSON-77",
        question: "What is the exact vault code for this project?"
    )

    /// Builds a recorded sample against ``seed``'s question.
    ///
    /// - Parameters:
    ///   - summary: The fold's summary text, or `nil` for a fold that produced
    ///     none.
    ///   - answer: The resumed session's answer.
    ///   - question: The question recorded for the sample. Defaults to
    ///     ``seed``'s own, which joins back to it.
    /// - Returns: The recorded sample.
    private static func diagnostic(
        summary: String?,
        answer: String,
        question: String = seed.question
    ) -> CompactionEvalSampleDiagnostic {
        CompactionEvalSampleDiagnostic(
            question: question,
            summary: summary,
            answer: answer,
            stagesApplied: ["ToolOutputElision", "TurnTruncation", "Summarization"],
            summarizerCallCount: 1
        )
    }

    @Test("an answer carrying the key phrase classifies as retained")
    func answerCarryingKeyPhraseIsRetained() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "The vault code is CRIMSON-77.",
            answer: "The vault code is CRIMSON-77.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .retained)
    }

    @Test("a summary carrying the key phrase and an answer that does not is an answering failure")
    func summaryCarriesKeyPhraseButAnswerDoesNot() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "2. Constraints & decisions — The vault code is CRIMSON-77.",
            answer: "Noted.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .answerMissedFactSummaryCarriedIt)
    }

    @Test("a summary that dropped the key phrase is a fold failure")
    func summaryWithoutKeyPhraseIsAFoldFailure() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "2. Constraints & decisions — the team discussed a vault.",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .summaryLostFact)
    }

    @Test("a fold that produced no summary is its own class")
    func absentSummaryIsItsOwnClass() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: nil,
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .foldProducedNoSummary)
    }

    @Test("a summary with no text is a fold failure, not a summary that lost the fact")
    func emptySummaryIsAFoldFailure() {
        // The gated run of 2026-08-17 recorded `Optional("")` on 19 of 19 seeds:
        // the fold ran, the summarizer answered, and the answer held no
        // characters. A `nil` guard alone filed every one of them under
        // `summaryLostFact`, which reads as a summary that forgot the fact.
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .foldProducedNoSummary)
    }

    @Test("a summary of whitespace alone is a fold failure too: it carries no summary either")
    func whitespaceOnlySummaryIsAFoldFailure() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "  \n\t  ",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .foldProducedNoSummary)
    }

    @Test("the rendered table names an empty summary, so a fold that stored no text is legible in the log")
    func renderedTableNamesAnEmptySummary() {
        // The printer wrote `summary=` with nothing after it, which reads as a
        // truncated line rather than as the measurement it is.
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.diagnostic(summary: "", answer: "Noted.")],
            seeds: [Self.seed]
        )
        let table = CompactionEvalFactRetentionReport.lines(of: findings).joined(separator: "\n")
        #expect(table.contains("summary=<empty>"))
        #expect(table.contains(CompactionEvalFactRetentionClass.foldProducedNoSummary.rawValue))
    }

    @Test("the key-phrase check is case-insensitive, exactly as the FactRetention metric's is")
    func keyPhraseMatchingIsCaseInsensitive() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: nil,
            answer: "the vault code is crimson-77.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .retained)
    }

    @Test("a recorded sample joins back to its seed's planted fact and summary evidence")
    func findingCarriesTheSeedsGroundTruth() throws {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.diagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
            seeds: [Self.seed]
        )
        let finding = try #require(findings.first)
        #expect(finding.seedID == Self.seed.id)
        #expect(finding.plantedFact == Self.seed.plantedFact)
        #expect(finding.factKeyPhrase == Self.seed.factKeyPhrase)
        #expect(finding.factInSummary == true)
        #expect(finding.classification == .answerMissedFactSummaryCarriedIt)
    }

    @Test("a recorded sample matching no seed is still classified, so no sample is dropped")
    func unmatchedSampleIsStillClassified() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.diagnostic(summary: "anything", answer: "anything", question: "a question no seed asks")],
            seeds: [Self.seed]
        )
        #expect(findings.count == 1)
        #expect(findings.first?.classification == .unrecognizedSample)
    }

    @Test("the counts name every class and sum to the number of recorded samples")
    func countsCoverEveryClassAndSumToTheSampleCount() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [
                Self.diagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                Self.diagnostic(summary: "CRIMSON-77", answer: "Noted."),
                Self.diagnostic(summary: "no code here", answer: "Noted."),
                Self.diagnostic(summary: nil, answer: "Noted."),
            ],
            seeds: [Self.seed]
        )
        let counts = CompactionEvalFactRetentionReport.counts(of: findings)
        #expect(counts.count == CompactionEvalFactRetentionClass.allCases.count)
        #expect(counts[.retained] == 1)
        #expect(counts[.answerMissedFactSummaryCarriedIt] == 1)
        #expect(counts[.summaryLostFact] == 1)
        #expect(counts[.foldProducedNoSummary] == 1)
        #expect(counts[.unrecognizedSample] == 0)
        #expect(counts.values.reduce(0, +) == findings.count)
    }

    @Test("the rendered table states each sample's fact, question, answer and summary")
    func renderedTableStatesEverySamplesEvidence() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.diagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
            seeds: [Self.seed]
        )
        let table = CompactionEvalFactRetentionReport.lines(of: findings).joined(separator: "\n")
        #expect(table.contains(Self.seed.id))
        #expect(table.contains(Self.seed.plantedFact))
        #expect(table.contains(Self.seed.question))
        #expect(table.contains("The vault code is CRIMSON-77."))
        #expect(table.contains("answer=Noted."))
        #expect(table.contains("factInSummary=true"))
        #expect(table.contains("folded=true"))
        #expect(table.contains(CompactionEvalFactRetentionClass.answerMissedFactSummaryCarriedIt.rawValue))
    }

    @Test("a stage list without Summarization records the sample as unfolded")
    func stagesWithoutSummarizationAreNotFolded() {
        let unfolded = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "Noted.",
            stagesApplied: ["ToolOutputElision", "TurnTruncation"],
            summarizerCallCount: 0
        )
        #expect(unfolded.folded == false)
        #expect(Self.diagnostic(summary: "s", answer: "a").folded == true)
    }

    @Test("every seed's question is unique, so a recorded sample joins back to exactly one seed")
    func everySeedQuestionIsUnique() {
        let questions = compactionEvalSeeds.map(\.question)
        #expect(Set(questions).count == questions.count)
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
    .enabled(if: compactionEvalsIntegrationEnabled),
    .exclusiveResidentModel(of: compactionEvalRealSubjectRunner),
    .timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))
)
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

        // Printed before the assertion so a run that misses the bar still
        // leaves the evidence behind: the mean alone cannot say whether a
        // failing sample lost its fact in the fold or in the answering turn,
        // and this table classifies every sample on exactly that question.
        let findings = CompactionEvalFactRetentionReport.findings(
            for: await compactionEvalRealSubjectRunner.recordedDiagnostics(),
            seeds: compactionEvalSeeds
        )
        for line in CompactionEvalFactRetentionReport.lines(of: findings) {
            print(line)
        }

        #expect(result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= 0.9)
    }
}
