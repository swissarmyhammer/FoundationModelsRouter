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

// MARK: - Measured sizing

/// What one token of this dataset's own English prose costs in UTF-8 bytes,
/// under the tokenizer of the model the gated eval runs
/// (``CompactionEvalRealModel/ref``).
///
/// The fold arithmetic spans two currencies, and this is the rate between them.
/// ``Summarization`` sizes a summarizer call's answer in REAL tokens
/// (``Summarization/minimumSummaryTokens``, ``Summarization/summaryTokenRatio``),
/// while ``Compactor`` measures a transcript in ESTIMATED ones — UTF-8 bytes
/// over a flat ``Compactor/charsPerTokenEstimate`` of 4.0. A fixture sized in
/// the estimate alone is exactly how `CompactionRoundTripIntegrationTests` ended
/// up below its own trigger (task ^wnj3ka3), so this dataset is sized in the
/// tokens the model really counts.
///
/// Measured with `AutoTokenizer` over the Muse Glimmer tokenizer out of the
/// local Hub cache, against this dataset's whole prose corpus — every fixture's
/// ``CompactionEvalFixtureSpec/context`` and facts, every acknowledgement, and
/// every ``compactionEvalFillerTurns`` prompt and reply: 31541 bytes against
/// 6564 tokens, which is 4.805 bytes for each token. Rounded up, so the summary
/// sizes this feeds are never under-stated.
let compactionEvalMeasuredBytesPerToken = 4.81

/// A summarizer whose answer is the length a real one writes.
///
/// A stub answering `"fake summary"` shrinks a fold whatever the seed holds, so
/// it proves the pipeline REACHED ``Summarization`` and nothing about whether
/// the fold survived `Compactor.compact`'s did-not-shrink guard. The gated run
/// of 2026-08-17 discarded 8 of the 9 folds the stub suite reported as reaching
/// the stage (task ^vjf3mdm).
///
/// `maxTokens` bounds the whole generation — the reasoning and the answer
/// together, see ``CompactionSummarizer/summarize(_:maxTokens:)`` — so the
/// answer alone is what is left once ``Summarization/reasoningTokenHeadroom`` is
/// taken off. The gated model always writes a `<think>` block and spends that
/// headroom on it, so the summary allowance is the answer, and an answer filling
/// it is the largest a real summarizer writes.
private struct RealisticSummaryLengthSummarizer: CompactionSummarizer {
    /// The headroom the stage under test adds on top of the summary allowance.
    ///
    /// Read from the same ``Summarization`` value the fold is given rather than
    /// restated, so this summarizer cannot drift away from the stage calling it.
    let reasoningTokenHeadroom: Int

    /// One sentence in the register a compaction summary is written in, repeated
    /// to reach a required size. ASCII throughout, so one character is one byte
    /// and the length asked for is the length produced.
    private static let sentence =
        "The conversation above stated a constraint the next turn has to keep, so this summary records it in the order it was given. "

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let summaryTokens = max(0, maxTokens - reasoningTokenHeadroom)
        let bytes = Int((Double(summaryTokens) * compactionEvalMeasuredBytesPerToken).rounded(.up))
        var text = ""
        while text.utf8.count < bytes {
            text += Self.sentence
        }
        return String(text.prefix(bytes))
    }
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

        try await Self.expectEverySeedFoldsThroughSummarization(
            with: FakeSummarizer(), answering: "a trivial summary")
    }

    @Test("every seed's fold is applied, not discarded, against a summarizer answering at a real summary's length")
    func everySeedFoldSurvivesARealisticSummary() async throws {
        // The assertion above proves the budget carries every seed INTO
        // `Summarization`. It cannot prove the fold that stage produced was
        // kept, because its summarizer answers in two words: a fold that
        // replaces a whole span with 12 bytes shrinks any transcript.
        //
        // `Compactor.compact` discards a fold that left the transcript no
        // smaller, and against a real model that is what these seeds used to
        // get: the gated run of 2026-08-17 reported `summarizerCalls=1` with an
        // empty stage list on 8 of the 9 samples that completed. The stage ran,
        // the summarizer answered, and the pipeline threw the fold away, so the
        // resumed session answered from the original turns and the dataset
        // measured nothing about compaction at all.
        //
        // So the summarizer here answers at the length the summary allowance
        // really buys, and this is the assertion that fails the moment a seed
        // stops folding — under a plain `swift test`, rather than 400 seconds
        // into a gated run. `CompactionEvalSeedSizingTests` states the
        // arithmetic behind it.
        let summarization = Summarization()
        try await Self.expectEverySeedFoldsThroughSummarization(
            with: RealisticSummaryLengthSummarizer(
                reasoningTokenHeadroom: summarization.reasoningTokenHeadroom),
            answering: "a summary of the length the allowance buys"
        )
    }

    /// Folds every seed with `summarizer` against ``compactionEvalDefaultBudget``
    /// and requires the whole pipeline to have run and been APPLIED.
    ///
    /// The budget is read from the same constant the evaluation itself defaults
    /// to, never restated as a literal: a copy would let the two drift, and
    /// these assertions exist to fail when that value stops forcing the fold.
    ///
    /// - Parameters:
    ///   - summarizer: The summarizer the fold calls.
    ///   - description: How the summarizer answers, named in the failure message
    ///     so a red run says which of the two callers below found the seed.
    /// - Throws: Whatever the fold throws.
    private static func expectEverySeedFoldsThroughSummarization(
        with summarizer: any CompactionSummarizer,
        answering description: String
    ) async throws {
        let budget = compactionEvalDefaultBudget
        for seed in compactionEvalSeeds {
            let (_, result) = try await Compactor.compact(
                Transcript(entries: seed.entries),
                budget: budget,
                summarizer: summarizer
            )
            #expect(
                result.stagesApplied == [
                    ToolOutputElision.stageName, TurnTruncation.stageName, Summarization.stageName,
                ],
                "seed \(seed.id) did not fold through Summarization against \(description): stagesApplied was \(result.stagesApplied)"
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

    @Test("every seed states its key phrase exactly once, so only the planted fact can carry it into a summary")
    func everySeedStatesItsKeyPhraseExactlyOnce() {
        // `FactRetention` passes when the resumed session's answer holds the key
        // phrase, and the classification calls the sample `retained` when the
        // summary holds it. A seed whose background prose also stated the phrase
        // would let a summary of that background satisfy both without the
        // planted fact ever surviving the fold — the dataset would then measure
        // its own filler rather than compaction.
        //
        // Counted without regard to case, because that is how the metric and the
        // classification both match.
        for seed in compactionEvalSeeds {
            let count = Self.occurrences(of: seed.factKeyPhrase, in: Self.transcriptText(of: seed))
            #expect(
                count == 1,
                "seed \(seed.id) states its key phrase \"\(seed.factKeyPhrase)\" \(count) times, not once"
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
            return text(of: response.segments)
        }
    }

    /// Every prompt and reply of `seed`'s built transcript, joined — the text a
    /// summarizer reading the folded span is shown.
    ///
    /// The tool-traffic entries a fixture may carry hold fixed strings
    /// (`recordFact`, `noted`, `recorded`) that no fixture's own content ever
    /// reaches, so leaving them out changes no answer this is asked for.
    ///
    /// - Parameter seed: The built seed to read.
    /// - Returns: The joined text, in transcript order.
    private static func transcriptText(of seed: CompactionEvalSeed) -> String {
        seed.entries.compactMap { entry -> String? in
            switch entry {
            case .prompt(let prompt):
                return text(of: prompt.segments)
            case .response(let response):
                return text(of: response.segments)
            case .instructions, .toolCalls, .toolOutput, .reasoning:
                return nil
            @unknown default:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    /// The joined content of every `.text` segment in `segments`, in order.
    ///
    /// - Parameter segments: The segments to flatten.
    /// - Returns: The joined text content.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case .text(let content) = segment else { return nil }
            return content.content
        }
        .joined(separator: "\n")
    }

    /// How many times `phrase` appears in `text`, matched the way
    /// `FactRetention` matches it: without regard to case.
    ///
    /// - Parameters:
    ///   - phrase: The phrase to count.
    ///   - text: The text to count it in.
    /// - Returns: The number of occurrences.
    private static func occurrences(of phrase: String, in text: String) -> Int {
        text.lowercased().components(separatedBy: phrase.lowercased()).count - 1
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

    @Test("the rendered table names a discarded fold, so a fold that ran and was thrown away is legible as one")
    func renderedTableNamesADiscardedFold() {
        // `Compactor.compact` reports a fold it discarded through the same
        // shortfall exit an unfolded transcript takes: no summary, no stage
        // applied. The table wrote `<none>` for it, which is what a fold that
        // never ran gets, so the gated run of 2026-08-17 printed 8 samples whose
        // summarizer had answered and whose fold had been thrown away as though
        // no stage had ever run.
        let discarded = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "I do not have that information.",
            stagesApplied: [],
            summarizerCallCount: 1
        )
        #expect(discarded.foldDiscarded)
        let table = Self.renderedTable(for: discarded)
        #expect(table.contains("summary=\(CompactionEvalFactRetentionReport.discardedSummaryMarker)"))
        #expect(!table.contains("summary=\(CompactionEvalFactRetentionReport.absentSummaryMarker)"))
    }

    @Test("a fold that never ran still renders as absent, so the discarded marker names only a discarded fold")
    func renderedTableStillNamesAFoldThatNeverRan() {
        // The other half of the same property. The deterministic stages landed
        // this transcript under target on their own, so no summarizer was ever
        // called and there is no fold to have discarded.
        let neverRan = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "I do not have that information.",
            stagesApplied: [ToolOutputElision.stageName],
            summarizerCallCount: 0
        )
        #expect(!neverRan.foldDiscarded)
        let table = Self.renderedTable(for: neverRan)
        #expect(table.contains("summary=\(CompactionEvalFactRetentionReport.absentSummaryMarker)"))
        #expect(!table.contains("summary=\(CompactionEvalFactRetentionReport.discardedSummaryMarker)"))
    }

    /// Renders the report table for one recorded sample against ``seed``.
    ///
    /// - Parameter diagnostic: The sample's recorded evidence.
    /// - Returns: The rendered table, one line per newline.
    private static func renderedTable(for diagnostic: CompactionEvalSampleDiagnostic) -> String {
        CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(for: [diagnostic], seeds: [seed])
        )
        .joined(separator: "\n")
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

// MARK: - Ungated seed sizing

/// Ungated proof that every seed's foldable span is large enough for a real
/// summary of it to be smaller (task ^vjf3mdm).
///
/// `CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` is
/// the mechanical gate — it folds every seed and requires the fold to be applied.
/// This suite states the arithmetic that gate rests on, so a seed that drifts
/// fails with a number rather than with "the fold was discarded".
///
/// Both bounds are stated in the tokens a live run really counts, never in the
/// character-ratio estimate alone. That distinction is what
/// `CompactionRoundTripIntegrationTests` missed twice (tasks 5m97h14 and
/// ^wnj3ka3): the estimate and the tokenizer do not agree, and a fixture sized
/// against the wrong one clears its bound on paper and misses it live. See
/// ``compactionEvalMeasuredBytesPerToken``.
@Suite("CompactionEvaluation seed sizing (ungated)")
struct CompactionEvalSeedSizingTests {
    /// How much larger a seed's foldable span must be than the largest summary a
    /// real summarizer writes for it.
    ///
    /// `1.5` says the fold has to save at least a third of the span it replaces.
    /// The slack is not decoration: the worst case below is computed at
    /// ``compactionEvalMeasuredBytesPerToken``, measured over this dataset's own
    /// prose, and a summary written in a wordier register costs more bytes for
    /// the same tokens. A third absorbs that comfortably. The measured margin is
    /// wider still — the tightest seed sits at 2.07 as the fixtures stand.
    private static let summaryShrinkClearance = 1.5

    /// The largest summary a real summarizer writes for a span this size, in the
    /// estimated tokens ``Compactor`` measures a transcript in.
    ///
    /// Every seed's span earns the FLOOR of the summary allowance,
    /// ``Summarization/minimumSummaryTokens``, because the other branch —
    /// ``Summarization/summaryTokenRatio`` of the span — only passes the floor on
    /// a span of roughly 2048 bytes or more. That branch cannot fail this bound
    /// at all: a quarter of a span, converted back into estimated tokens at the
    /// measured rate, is `0.25 * 4.81 / 4.0` — under a third of the span it
    /// condensed — so a summary that large shrinks the transcript by
    /// construction, whatever the span. The floor is the only branch that can
    /// leave a fold no smaller than what it replaced, so the floor is what this
    /// asserts against.
    private static var worstCaseSummaryEstimatedTokens: Int {
        Int(
            (Double(Summarization.minimumSummaryTokens) * compactionEvalMeasuredBytesPerToken
                / Compactor.charsPerTokenEstimate)
                .rounded(.up))
    }

    /// The estimated token count of `seed`'s foldable span — every turn
    /// ``Summarization`` replaces with one summary entry.
    ///
    /// Partitioned through the same ``TranscriptTurns`` split the stage itself
    /// uses, at the stage's own ``Summarization/keepRecentTurns``, so this
    /// measures what a fold really replaces rather than a model of it.
    ///
    /// - Parameter seed: The seed to measure.
    /// - Returns: The span's size in estimated tokens.
    private static func foldableSpanEstimatedTokens(of seed: CompactionEvalSeed) -> Int {
        let (_, turns) = TranscriptTurns.split(seed.entries)
        let (old, _) = TranscriptTurns.partition(turns, keepRecentTurns: Summarization().keepRecentTurns)
        return Compactor.estimatedTokenCount(of: Transcript(entries: old.flatMap(\.entries)))
    }

    @Test("every seed's foldable span outweighs the largest real summary of it, so the fold is worth applying")
    func everySeedsFoldableSpanOutweighsARealSummary() {
        // The lower bound of the band. Before task ^vjf3mdm a seed's whole span
        // was one fact sentence and its acknowledgement — a few hundred bytes,
        // against a 128-token floor a real model spends roughly 615 bytes on. The
        // fold cost more than it saved, and `Compactor.compact` was right to
        // throw it away.
        let worstCase = Self.worstCaseSummaryEstimatedTokens
        let required = Int((Double(worstCase) * Self.summaryShrinkClearance).rounded(.up))
        for seed in compactionEvalSeeds {
            let span = Self.foldableSpanEstimatedTokens(of: seed)
            #expect(
                span >= required,
                "seed \(seed.id)'s foldable span estimates \(span) tokens, under the \(required) it needs to clear a real \(worstCase)-token summary by \(Self.summaryShrinkClearance)"
            )
        }
    }

    @Test("every seed's foldable span still fits one summarizer call, so a fold makes exactly one round trip")
    func everySeedsFoldableSpanFitsOneSummarizerCall() {
        // The upper bound of the same band. `Summarization` splits a span past
        // `maxChunkTokens` into several map calls plus a reduce call, so a seed
        // that grew past it would multiply the gated eval's model calls — already
        // over its time limit, task ^fz49qds — and fold in a shape this dataset
        // does not measure.
        //
        // Read against the span's own estimate. Rendering the span for the
        // summarizer adds a role label to each entry, which only adds, and the
        // margin here is wide enough that no per-entry label can close it.
        let maxChunkTokens = Summarization().maxChunkTokens
        for seed in compactionEvalSeeds {
            let span = Self.foldableSpanEstimatedTokens(of: seed)
            #expect(
                span <= maxChunkTokens,
                "seed \(seed.id)'s foldable span estimates \(span) tokens, over the \(maxChunkTokens) one summarizer call condenses"
            )
        }
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
