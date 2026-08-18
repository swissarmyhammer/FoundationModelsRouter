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

/// The SECOND opt-in environment variable, which moves the gated compaction
/// eval off its representative subset and onto the whole hand-written dataset.
///
/// Read exactly as `compactionEvalsIntegrationEnvVar` is read, and beside it, so
/// the target has one gating mechanism rather than two. It never enables
/// anything on its own: an unset `FM_ROUTER_INTEGRATION_TESTS` still skips both
/// tiers, as it does for every other real-model suite in this repository.
///
/// The two tiers are exclusive. Set alone, `FM_ROUTER_INTEGRATION_TESTS` runs
/// the subset; set together with this one, the whole dataset runs and the subset
/// tier steps aside rather than measuring the same seeds again ahead of it.
private let compactionEvalsFullDatasetEnvVar = "FM_ROUTER_COMPACTION_EVAL_FULL_DATASET"

private var compactionEvalsFullDatasetEnabled: Bool {
    ProcessInfo.processInfo.environment[compactionEvalsFullDatasetEnvVar] != nil
}

// MARK: - Measured tier limits

/// The wall-clock ceiling the DEFAULT gated tier's `@Test` runs under, in
/// minutes.
///
/// Measurement gives this value. `FM_ROUTER_INTEGRATION_TESTS=1 swift test
/// --filter CompactionEvaluationIntegrationTests`, run on 2026-08-17 against
/// the seven seeds of ``compactionEvalRepresentativeSubsetIDs``, passed in
/// **1644.7 seconds — 27.4 minutes**, with all seven samples measured and a
/// mean `FactRetention` of 1.0. That is 235 seconds for each sample, and the
/// model load is inside it: ``CompactionEvalRealSubjectRunner`` resolves
/// ``CompactionEvalRealModel/ref`` on the first sample's own call.
///
/// Each sample pays for two real generations — one summarizer call inside the
/// fold and one answering turn on the resumed session — and each is bounded in
/// thousands of output tokens rather than hundreds, because the gated model
/// always writes a `<think>` block first. See
/// ``GatedRealModelBudget/responseTokenCeiling`` and
/// ``Summarization/reasoningTokenHeadroom``. That is what a seed really costs,
/// and it is why a subset of seven costs what the whole dataset used to appear
/// to.
///
/// The margin over the measurement is 2.6 minutes, and it is stated rather than
/// hidden. Two things can spend it. ``CompactionEvalRealSubjectRunner``
/// deliberately leaves the provider's own sampling in place rather than pinning
/// `.greedy`, so two runs of identical code generate answers of different
/// lengths; and a machine that has never fetched the model pays that download
/// inside this limit. A run that ends on the limit now names the seeds it never
/// reached — see ``CompactionEvalFactRetentionReport/lines(of:expecting:)`` —
/// so an overrun reads as an overrun rather than as a smaller clean sheet.
///
/// The 20 minutes ``gatedEvalSuiteTimeLimitMinutes`` states, which this suite
/// ran under before, is below the measurement. That is the limit the gated run
/// of 2026-08-17 exceeded, nine seeds into the whole dataset (task ^fz49qds).
let compactionEvalSubsetTimeLimitMinutes = 30

/// The wall-clock ceiling the opt-in whole-dataset tier's `@Test` runs under,
/// in minutes.
///
/// DERIVED, not measured. Timing this tier costs the hour and a half the
/// constant exists to bound, so the value is computed from the subset
/// measurement above instead, and this comment says so rather than letting a
/// reader take it for a measured one.
///
/// The arithmetic: 1644.7 seconds over seven samples is 235 seconds for each,
/// and twenty-four samples at that rate is 5639 seconds — 94 minutes. That rate
/// carries the one-time model load spread across seven samples, so multiplying
/// it by twenty-four charges the load more than three times over. The derived
/// figure therefore over-states the work, which is the right direction for a
/// ceiling.
///
/// 120 leaves 26 minutes over the derived 94. The first run of this tier should
/// record its real duration here in place of the derivation.
let compactionEvalFullDatasetTimeLimitMinutes = 120

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

/// The ceiling one summarizer call of an eval-sized fold is really given:
/// ``Summarization/minimumSummaryTokens`` — the allowance every seed's span
/// earns — plus ``Summarization/reasoningTokenHeadroom``.
///
/// Read off the stage's own values rather than restated as a literal, so a
/// recorded sample here can never claim a ceiling the stage does not hand out.
let compactionEvalSummarizerCeiling =
    Summarization.minimumSummaryTokens + Summarization().reasoningTokenHeadroom

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
/// taken off: the summary allowance.
///
/// An answer filling that allowance is the largest a summarizer TOLD the
/// allowance writes, and that qualifier is measured rather than assumed. The
/// gated run of 2026-08-17 (task ^fm5ddk9) called every one of 7 seeds at a
/// ceiling of 4224 tokens against an allowance of 128, and every one answered
/// with 374 to 698 real tokens — 2.9x to 5.5x the allowance, because nothing in
/// the assembled prompt had ever named it. `Summarization` now states the
/// allowance to the model in its own length directive, so this summarizer models
/// a summarizer that honors the stated bound. That is the contract under test;
/// `Compactor.compact`'s did-not-shrink guard is what still catches a summarizer
/// that does not.
///
/// It answers slightly OVER the stated bound on purpose: the directive states
/// the allowance in characters (128 tokens at `Compactor.charsPerTokenEstimate`
/// is 512), and this answers the allowance in REAL tokens at
/// ``compactionEvalMeasuredBytesPerToken`` — about 616 bytes. So a seed that
/// clears this gate clears a summary 20% larger than the directive asks for.
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
        // So the summarizer here answers at the length the stated summary
        // allowance buys — see `RealisticSummaryLengthSummarizer` for what the
        // real model does when the allowance is never stated to it, which is
        // the defect `^fm5ddk9` measured — and this is the assertion that fails
        // the moment a seed
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
    /// Flattened by ``Summarization/text(of:)``, the production function a fold
    /// itself reads an entry's segments with, so what this measures is the text
    /// a summarizer really sees rather than a test's own idea of it.
    ///
    /// - Parameter seed: The built seed to read.
    /// - Returns: The replies, in transcript order.
    private static func assistantReplies(of seed: CompactionEvalSeed) -> [String] {
        seed.entries.compactMap { entry -> String? in
            guard case .response(let response) = entry else { return nil }
            return Summarization.text(of: response.segments)
        }
    }

    /// Every prompt and reply of `seed`'s built transcript, joined — the text a
    /// summarizer reading the folded span is shown.
    ///
    /// The tool-traffic entries a fixture may carry hold fixed strings
    /// (`recordFact`, `noted`, `recorded`) that no fixture's own content ever
    /// reaches, so leaving them out changes no answer this is asked for.
    ///
    /// Flattened by ``Summarization/text(of:)``, for the reason
    /// ``assistantReplies(of:)`` states.
    ///
    /// - Parameter seed: The built seed to read.
    /// - Returns: The joined text, in transcript order.
    private static func transcriptText(of seed: CompactionEvalSeed) -> String {
        seed.entries.compactMap { entry -> String? in
            switch entry {
            case .prompt(let prompt):
                return Summarization.text(of: prompt.segments)
            case .response(let response):
                return Summarization.text(of: response.segments)
            case .instructions, .toolCalls, .toolOutput, .reasoning:
                return nil
            @unknown default:
                return nil
            }
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

    /// A second seed, used by the tests that need a tier of more than one seed
    /// so a run can reach some of it and not the rest.
    ///
    /// Its question differs from ``seed``'s, which is what lets a recorded
    /// sample join back to exactly one of the two.
    private static let unreachedSeed = CompactionEvalSeed(
        id: "probe-seed-two",
        entries: [],
        plantedFact: "The staging database listens on port 6543.",
        factKeyPhrase: "PORT-6543",
        question: "Which port does the staging database listen on?"
    )

    /// Both probe seeds, in the order a tier would state them — the seed set
    /// the unreached-seed tests hold a run against.
    private static let bothSeeds = [seed, unreachedSeed]

    /// Builds one recorded summarizer call answering `answer` at
    /// ``compactionEvalSummarizerCeiling``.
    ///
    /// - Parameter answer: The text the summarizer answered.
    /// - Returns: The recorded call.
    private static func makeSummarizerCall(answering answer: String) -> CompactionEvalSummarizerCall {
        CompactionEvalSummarizerCall(maxTokens: compactionEvalSummarizerCeiling, answer: answer)
    }

    /// Builds a recorded sample against ``seed``'s question.
    ///
    /// The recorded call answers exactly `summary`, which is what a fold that
    /// was applied really records: the stored summary is the summarizer's own
    /// last answer.
    ///
    /// - Parameters:
    ///   - summary: The fold's summary text, or `nil` for a fold that produced
    ///     none.
    ///   - answer: The resumed session's answer.
    ///   - question: The question recorded for the sample. Defaults to
    ///     ``seed``'s own, which joins back to it.
    /// - Returns: The recorded sample.
    private static func makeDiagnostic(
        summary: String?,
        answer: String,
        question: String = seed.question
    ) -> CompactionEvalSampleDiagnostic {
        CompactionEvalSampleDiagnostic(
            question: question,
            summary: summary,
            answer: answer,
            stagesApplied: ["ToolOutputElision", "TurnTruncation", "Summarization"],
            summarizerCalls: [makeSummarizerCall(answering: summary ?? "")]
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
            for: [Self.makeDiagnostic(summary: "", answer: "Noted.")],
            seeds: [Self.seed]
        )
        let table = CompactionEvalFactRetentionReport.lines(of: findings, expecting: [Self.seed])
            .joined(separator: "\n")
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
            summarizerCalls: [Self.makeSummarizerCall(answering: "a summary the pipeline threw away")]
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
            summarizerCalls: []
        )
        #expect(!neverRan.foldDiscarded)
        let table = Self.renderedTable(for: neverRan)
        #expect(table.contains("summary=\(CompactionEvalFactRetentionReport.absentSummaryMarker)"))
        #expect(!table.contains("summary=\(CompactionEvalFactRetentionReport.discardedSummaryMarker)"))
        // No summarizer ever answered, so there is no discarded summary to
        // measure and the stanza states none.
        #expect(!table.contains("  discarded="))
    }

    @Test("a discarded fold states how large the summary that lost was, beside the span it was to replace")
    func renderedTableStatesTheDiscardedSummarysSize() throws {
        // `<discarded>` alone says a fold ran and was thrown away. It does not
        // say by how much, and on the shortfall path `CompactionResult.summary`
        // is `nil`, so the size of the summary that lost was recorded nowhere at
        // all: the gated run of 2026-08-17 printed `summary=<discarded>` on 7 of
        // 7 seeds and left the next run unable to tell a fold that missed by a
        // few percent from one that missed by a multiple.
        //
        // Read against a real dataset seed rather than the empty probe seeds
        // above, so the span the line states is a span a fold really replaces.
        let seed = try #require(compactionEvalSeeds.first)
        let answer = String(repeating: "The conversation stated a constraint. ", count: 200)
        let discarded = CompactionEvalSampleDiagnostic(
            question: seed.question,
            summary: nil,
            answer: "I do not have that information.",
            stagesApplied: [],
            summarizerCalls: [Self.makeSummarizerCall(answering: answer)]
        )
        let table = CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(for: [discarded], seeds: [seed]),
            expecting: [seed]
        )
        .joined(separator: "\n")

        #expect(table.contains("discarded=\(answer.utf8.count) bytes"))
        #expect(table.contains("summaryTokens=\(Summarization.estimatedTokens(of: answer))"))
        #expect(table.contains("spanTokens=\(seed.foldableSpanEstimatedTokens)"))
        #expect(table.contains("ceiling=\(compactionEvalSummarizerCeiling)"))
        // The text itself, bounded: enough of it to read what the model wrote,
        // and never the whole of a summary that ran to thousands of bytes.
        #expect(table.contains(CompactionEvalFactRetentionReport.discardedSummaryTruncationMarker))
        #expect(!table.contains(answer))
    }

    /// Renders the report table for one recorded sample against ``seed``.
    ///
    /// - Parameter diagnostic: The sample's recorded evidence.
    /// - Returns: The rendered table, one line per newline.
    private static func renderedTable(for diagnostic: CompactionEvalSampleDiagnostic) -> String {
        CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(for: [diagnostic], seeds: [seed]),
            expecting: [seed]
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
            for: [Self.makeDiagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
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
            for: [Self.makeDiagnostic(summary: "anything", answer: "anything", question: "a question no seed asks")],
            seeds: [Self.seed]
        )
        #expect(findings.count == 1)
        #expect(findings.first?.classification == .unrecognizedSample)
    }

    @Test("the counts name every class and sum to the number of recorded samples")
    func countsCoverEveryClassAndSumToTheSampleCount() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "Noted."),
                Self.makeDiagnostic(summary: "no code here", answer: "Noted."),
                Self.makeDiagnostic(summary: nil, answer: "Noted."),
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
            for: [Self.makeDiagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
            seeds: [Self.seed]
        )
        let table = CompactionEvalFactRetentionReport.lines(of: findings, expecting: [Self.seed])
            .joined(separator: "\n")
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
            summarizerCalls: []
        )
        #expect(unfolded.folded == false)
        #expect(Self.makeDiagnostic(summary: "s", answer: "a").folded == true)
    }

    @Test("every seed's question is unique, so a recorded sample joins back to exactly one seed")
    func everySeedQuestionIsUnique() {
        let questions = compactionEvalSeeds.map(\.question)
        #expect(Set(questions).count == questions.count)
    }

    @Test("the table heads itself with the seeds it measured out of the seeds it was given")
    func tableStatesHowManyOfTheTiersSeedsItMeasured() {
        // A run the suite time limit cut short recorded a sample for some of its
        // seeds and none for the rest. The head counted the samples alone —
        // "9 samples" — which reads as a whole measurement of a nine-seed tier
        // rather than as a third of a 24-seed one (task ^fz49qds).
        let table = CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(
                for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
                seeds: Self.bothSeeds
            ),
            expecting: Self.bothSeeds
        )
        .joined(separator: "\n")
        #expect(table.contains("1 of 2 seeds measured"))
    }

    @Test("a run cut short names the seeds it never reached, so a partial table cannot read as a whole one")
    func runCutShortNamesTheSeedsItNeverReached() {
        // The evidence a run leaves behind is the samples that ran. Nothing in
        // the table said the rest never ran, so the `counts:` tally summed to
        // the samples present and read as a clean sheet over the whole dataset.
        let table = CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(
                for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
                seeds: Self.bothSeeds
            ),
            expecting: Self.bothSeeds
        )
        .joined(separator: "\n")
        #expect(table.contains("unreached: 1 of 2 seeds never ran"))
        #expect(table.contains(Self.unreachedSeed.id))
        #expect(!table.contains(CompactionEvalFactRetentionReport.everySeedReachedMarker))
    }

    @Test("a run that reached every seed says so, so the absence of a name is stated rather than inferred")
    func completeRunStatesThatEverySeedRan() {
        // The other half of the same property. A table with no unreached line at
        // all would leave a reader unable to tell a complete run from a printer
        // that never states one.
        let table = CompactionEvalFactRetentionReport.lines(
            of: CompactionEvalFactRetentionReport.findings(
                for: [
                    Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                    Self.makeDiagnostic(
                        summary: "PORT-6543", answer: "It is PORT-6543.", question: Self.unreachedSeed.question),
                ],
                seeds: Self.bothSeeds
            ),
            expecting: Self.bothSeeds
        )
        .joined(separator: "\n")
        #expect(table.contains("unreached: \(CompactionEvalFactRetentionReport.everySeedReachedMarker)"))
        #expect(table.contains("2 of 2 seeds measured"))
    }

    @Test("an unreached seed is named by id, and a reached one is not")
    func unreachedSeedIDsNameOnlyTheSeedsNoSampleCovered() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
            seeds: Self.bothSeeds
        )
        #expect(
            CompactionEvalFactRetentionReport.unreachedSeedIDs(in: findings, expecting: Self.bothSeeds)
                == [Self.unreachedSeed.id])
    }
}

// MARK: - Hermetic progress-line rendering

/// Hermetic proof that a gated tier leaves a live trail naming where a run
/// stopped (task ^h2xxsse).
///
/// ``CompactionEvalRealSubjectRunner`` records a sample only once its fold AND
/// its answering turn have both finished, and ``expectFactRetention(of:)``
/// prints its table once at the very end. So a run the suite time limit cut
/// short reported one bit — "not finished". The gated run of 2026-08-18 hit the
/// subset tier's own 1800-second limit with 0 of 7 seeds measured, against two
/// earlier runs of the same tier that measured 7 of 7 in 1644.7 s and 1685.9 s,
/// and nothing it printed could say whether the model load, one fold, or one
/// answering turn had spent the time.
///
/// These tests pin the lines that answer that question: the model load stated
/// apart from any sample, and each sample naming the step it entered and the
/// step it left, with the seconds each one took.
@Suite("CompactionEvaluation progress lines")
struct CompactionEvalProgressLogTests {
    /// Where in its tier the sample ``label`` names stands — the middle, so a
    /// rendered ordinal that silently used the total (or the reverse) shows.
    private static let sampleOrdinal = 3

    /// How many seeds the tier ``label`` names states.
    private static let tierSeedCount = compactionEvalRepresentativeSeeds.count

    /// The seed id ``label`` names.
    private static let sampleSeedID = "probe-seed"

    /// A sample label in the middle of its tier.
    private static let label = CompactionEvalSampleLabel(
        ordinal: sampleOrdinal, total: tierSeedCount, seedID: sampleSeedID)

    /// The model reference the model-load lines name.
    private static let ref = CompactionEvalRealModel.ref.stringValue

    /// A duration with a fractional part the rendering must keep, so a
    /// whole-second truncation is visible.
    ///
    /// Deliberately not a value that sits exactly half way between two rendered
    /// places: `96.25` is not representable in binary, and `%.1f` rounds it
    /// down to `96.2` rather than up. A fixture on that edge would measure the
    /// C library's rounding rule instead of this eval's own rendering.
    private static let stepSeconds = 96.24

    /// A larger duration, standing for the sample's elapsed total at the point
    /// a step returned.
    private static let elapsedSeconds = 214.68

    /// A duration under one second, which a whole-second rendering would state
    /// as a zero.
    private static let subSecondSeconds = 0.44

    /// The subset tier's own measured run of 2026-08-17 — the largest duration
    /// a progress line of this eval ever has to state.
    private static let measuredSubsetRunSeconds = 1644.7

    @Test("every progress line opens with the one prefix a reader greps for")
    func everyProgressLineCarriesTheSharedPrefix() {
        var lines = [
            CompactionEvalProgressLog.makeModelLoadStartedLine(ref: Self.ref),
            CompactionEvalProgressLog.makeModelLoadReturnedLine(ref: Self.ref, seconds: Self.stepSeconds),
        ]
        for step in CompactionEvalProgressStep.allCases {
            lines.append(
                CompactionEvalProgressLog.makeStepStartedLine(
                    step, sample: Self.label, elapsedSeconds: Self.elapsedSeconds))
            lines.append(
                CompactionEvalProgressLog.makeStepReturnedLine(
                    step,
                    sample: Self.label,
                    elapsedSeconds: Self.elapsedSeconds,
                    stepSeconds: Self.stepSeconds,
                    detail: ""
                ))
        }
        for line in lines {
            #expect(line.hasPrefix(CompactionEvalProgressLog.linePrefix))
        }
    }

    @Test("the model load is timed on its own, apart from any sample")
    func modelLoadIsStatedApartFromTheSamples() {
        let started = CompactionEvalProgressLog.makeModelLoadStartedLine(ref: Self.ref)
        let returned = CompactionEvalProgressLog.makeModelLoadReturnedLine(
            ref: Self.ref, seconds: Self.stepSeconds)

        #expect(started.contains("ref=\(Self.ref)"))
        #expect(returned.contains("ref=\(Self.ref)"))
        #expect(returned.contains("took=\(CompactionEvalProgressLog.makeSecondsText(Self.stepSeconds))"))
        // A load that has not finished has no duration to state, and a load
        // that has is not a sample — a reader who sees one number must never
        // read it as a seed's cost.
        #expect(!started.contains("took="))
        #expect(!started.contains("sample="))
        #expect(!returned.contains("sample="))
    }

    @Test("a started line names the step it entered and states no duration for it")
    func startedLineNamesTheStepAndStatesNoDuration() {
        let line = CompactionEvalProgressLog.makeStepStartedLine(
            .fold, sample: Self.label, elapsedSeconds: Self.elapsedSeconds)

        #expect(line.contains("\(CompactionEvalProgressStep.fold.rawValue) \(CompactionEvalProgressLog.startedMarker)"))
        #expect(line.contains("elapsed=\(CompactionEvalProgressLog.makeSecondsText(Self.elapsedSeconds))"))
        // The step has not finished, so it has no duration of its own yet.
        #expect(!line.contains("took="))
    }

    @Test("a returned line states the step's own duration beside the sample's elapsed total")
    func returnedLineStatesTheStepsOwnDurationBesideTheElapsedTotal() {
        let line = CompactionEvalProgressLog.makeStepReturnedLine(
            .answer,
            sample: Self.label,
            elapsedSeconds: Self.elapsedSeconds,
            stepSeconds: Self.stepSeconds,
            detail: ""
        )

        #expect(
            line.contains("\(CompactionEvalProgressStep.answer.rawValue) \(CompactionEvalProgressLog.returnedMarker)"))
        #expect(line.contains("elapsed=\(CompactionEvalProgressLog.makeSecondsText(Self.elapsedSeconds))"))
        #expect(line.contains("took=\(CompactionEvalProgressLog.makeSecondsText(Self.stepSeconds))"))
    }

    @Test("a sample is named by its seed and by its position in the tier")
    func sampleIsNamedByItsSeedAndItsPositionInTheTier() {
        let line = CompactionEvalProgressLog.makeStepStartedLine(
            .fold, sample: Self.label, elapsedSeconds: 0)

        #expect(line.contains("sample=\(Self.sampleOrdinal)/\(Self.tierSeedCount)"))
        #expect(line.contains("seed=\(Self.sampleSeedID)"))
    }

    @Test("a label built from a seed's question names that seed")
    func labelBuiltFromASeedsQuestionNamesThatSeed() throws {
        let seeds = compactionEvalRepresentativeSeeds
        let seed = try #require(seeds.last)
        let label = CompactionEvalSampleLabel(
            ordinal: seeds.count,
            of: seeds.count,
            question: seed.question,
            in: CompactionEvalSeed.keyedByQuestion(seeds)
        )

        #expect(label.seedID == seed.id)
        #expect(label.ordinal == seeds.count)
        #expect(label.total == seeds.count)
    }

    @Test("a label whose question matches no seed is still named, by the report's own marker")
    func labelWhoseQuestionMatchesNoSeedIsStillNamed() {
        let seeds = compactionEvalRepresentativeSeeds
        let label = CompactionEvalSampleLabel(
            ordinal: 1,
            of: seeds.count,
            question: "a question no seed asks",
            in: CompactionEvalSeed.keyedByQuestion(seeds)
        )

        #expect(label.seedID == CompactionEvalFactRetentionReport.unmatchedSeedID)
    }

    @Test("keying the seeds by question keeps every seed")
    func keyingTheSeedsByQuestionKeepsEverySeed() {
        let seeds = compactionEvalSeeds
        let keyed = CompactionEvalSeed.keyedByQuestion(seeds)

        #expect(keyed.count == seeds.count)
        for seed in seeds {
            #expect(keyed[seed.question]?.id == seed.id)
        }
    }

    @Test("a fold's returned line states what its summarizer produced")
    func foldReturnedLineStatesWhatTheSummarizerProduced() {
        let summary = "2. Stated facts — the staging database listens on port 6543."
        let detail = CompactionEvalProgressLog.makeFoldDetail(
            stagesApplied: [Summarization.stageName],
            summarizerCalls: [
                CompactionEvalSummarizerCall(maxTokens: compactionEvalSummarizerCeiling, answer: summary)
            ]
        )

        #expect(detail.contains("stages=\(Summarization.stageName)"))
        #expect(detail.contains("summarizerCalls=1"))
        #expect(detail.contains("summarizerBytes=\(summary.utf8.count)"))
    }

    @Test("a fold that called no summarizer states zero bytes rather than nothing")
    func foldThatCalledNoSummarizerStatesZeroBytes() {
        let detail = CompactionEvalProgressLog.makeFoldDetail(
            stagesApplied: [ToolOutputElision.stageName], summarizerCalls: [])

        #expect(detail.contains("summarizerCalls=0"))
        #expect(detail.contains("summarizerBytes=0"))
    }

    @Test("an answering turn's returned line states the answer's size")
    func answerReturnedLineStatesTheAnswersSize() {
        let answer = "The staging database listens on port 6543."
        let detail = CompactionEvalProgressLog.makeAnswerDetail(answer: answer)

        #expect(detail.contains("answerBytes=\(answer.utf8.count)"))
    }

    @Test("seconds are stated to one decimal place, so a step under a second is not a zero")
    func secondsAreStatedToOneDecimalPlace() {
        #expect(CompactionEvalProgressLog.makeSecondsText(Self.subSecondSeconds) == "0.4s")
        #expect(CompactionEvalProgressLog.makeSecondsText(Self.stepSeconds) == "96.2s")
        #expect(CompactionEvalProgressLog.makeSecondsText(Self.measuredSubsetRunSeconds) == "1644.7s")
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

    /// The largest summary a summarizer honoring its stated allowance writes for
    /// a span this size, in the estimated tokens ``Compactor`` measures a
    /// transcript in.
    ///
    /// "Honoring its stated allowance" is the whole qualifier, and it is
    /// measured. Before `Summarization` stated the allowance in its own length
    /// directive, the gated run of 2026-08-17 measured summaries of 450 to 840
    /// estimated tokens against this bound of 154 — task ^fm5ddk9. The bound
    /// below is what the fold ASKS for; `Compactor.compact`'s did-not-shrink
    /// guard is what happens when a model does not deliver it.
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
            let span = seed.foldableSpanEstimatedTokens
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
            let span = seed.foldableSpanEstimatedTokens
            #expect(
                span <= maxChunkTokens,
                "seed \(seed.id)'s foldable span estimates \(span) tokens, over the \(maxChunkTokens) one summarizer call condenses"
            )
        }
    }
}

// MARK: - Ungated gated-subset coverage

/// Ungated proof that the seed subset the default gated tier measures still
/// spans every property the whole dataset varies (task ^fz49qds).
///
/// The default tier runs a subset because the whole dataset does not fit a
/// short wall-clock limit, and a subset is only worth running when it is
/// representative. "Representative" is a property of the fixtures, so it is
/// checked against the fixtures rather than argued for in a comment: an edit
/// that drops the subset's last tool-traffic seed, or its longest recency
/// window, fails under a plain `swift test` instead of silently narrowing what
/// the gated tier measures.
///
/// Every bound below is read from ``compactionEvalFixtureSpecs`` itself, never
/// restated as a literal, so a fixture that widens the dataset widens what the
/// subset must cover.
@Suite("CompactionEvaluation gated subset coverage (ungated)")
struct CompactionEvalRepresentativeSubsetTests {
    /// How many seeds the subset may hold.
    ///
    /// The lower bound keeps the subset wide enough for a mean over it to mean
    /// anything, and the upper bound is what
    /// ``compactionEvalSubsetTimeLimitMinutes`` was measured against — a subset
    /// that grew past it would no longer fit the limit that measurement bought.
    private static let subsetSizeBand = 6...8

    /// The fixture specs the subset names, in dataset order.
    ///
    /// Read back out of ``compactionEvalFixtureSpecs`` because
    /// ``CompactionEvalSeed`` carries none of the properties this suite checks —
    /// the built seed keeps its entries, its planted fact and its question, and
    /// drops the fact count, the delivery and the recency-window size.
    private static let subsetSpecs = compactionEvalFixtureSpecs.filter {
        compactionEvalRepresentativeSubsetIDs.contains($0.id)
    }

    @Test("every id the subset names is a fixture the dataset holds")
    func everySubsetIDNamesAFixture() {
        let datasetIDs = Set(compactionEvalFixtureSpecs.map(\.id))
        for id in compactionEvalRepresentativeSubsetIDs {
            #expect(datasetIDs.contains(id), "the gated subset names \"\(id)\", which is no fixture of this dataset")
        }
    }

    @Test("the built subset seeds are exactly the seeds the subset names")
    func subsetSeedsAreTheSeedsTheSubsetNames() {
        #expect(
            Set(compactionEvalRepresentativeSeeds.map(\.id)) == Set(compactionEvalRepresentativeSubsetIDs),
            "the built subset seeds are \(compactionEvalRepresentativeSeeds.map(\.id))"
        )
    }

    @Test("the subset stays inside the size band its time limit was measured against")
    func subsetStaysInsideItsSizeBand() {
        #expect(
            Self.subsetSizeBand.contains(compactionEvalRepresentativeSeeds.count),
            "the gated subset holds \(compactionEvalRepresentativeSeeds.count) seeds, outside \(Self.subsetSizeBand)"
        )
    }

    @Test("the subset carries every head size the dataset varies, so a multi-fact fold is measured")
    func subsetCarriesEveryFactCount() {
        // A single-fact head gives the summarizer one thing to keep. A three-fact
        // head makes it choose what to keep, which is the harder measurement, and
        // a subset of single-fact heads alone would never make it.
        let datasetCounts = Set(compactionEvalFixtureSpecs.map(\.facts.count))
        let subsetCounts = Set(Self.subsetSpecs.map(\.facts.count))
        #expect(subsetCounts == datasetCounts, "the gated subset carries head sizes \(subsetCounts.sorted())")
    }

    @Test("the subset carries both tool-traffic and plain-reply delivery")
    func subsetCarriesBothDeliveries() {
        // `ToolOutputElision` runs before `Summarization` and only has work to do
        // on a head that carries tool traffic, so a subset of plain-reply seeds
        // alone would leave the first stage of the pipeline unmeasured.
        let deliveries = Set(Self.subsetSpecs.map(\.probedFactViaTool))
        #expect(deliveries == [true, false], "the gated subset carries deliveries \(deliveries)")
    }

    @Test("the subset spans the dataset's whole recency-window range")
    func subsetSpansTheWholeRecentTurnRange() {
        // The recency window is what `Summarization` keeps verbatim, so it decides
        // how much of the transcript the fold leaves alone. The shortest and the
        // longest window in the dataset are the two ends of that, and the subset
        // carries both.
        let dataset = compactionEvalFixtureSpecs.map(\.recentTurnCount)
        let subset = Self.subsetSpecs.map(\.recentTurnCount)
        #expect(subset.min() == dataset.min(), "the gated subset's shortest recency window is \(subset.min() ?? 0)")
        #expect(subset.max() == dataset.max(), "the gated subset's longest recency window is \(subset.max() ?? 0)")
    }

    @Test("the subset probes a first fact, a fact that is not first, and a last fact")
    func subsetProbesEveryPositionInTheHead() {
        // Where the probed fact sits in the head decides what the summary has to
        // reach past to carry it. A subset that only ever probed the first fact
        // would measure a summary that never had to choose between facts.
        #expect(Self.subsetSpecs.contains { $0.probedFactIndex == 0 }, "the gated subset probes no first fact")
        #expect(Self.subsetSpecs.contains { $0.probedFactIndex > 0 }, "the gated subset probes no later fact")
        #expect(
            Self.subsetSpecs.contains { $0.probedFactIndex == $0.facts.count - 1 },
            "the gated subset probes no last fact"
        )
    }
}

// MARK: - Gated real-model eval

/// Loads ``CompactionEvalRealModel`` at most once for the gated `@Test`
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
/// would let a table carry samples the other tier ran. Only one of the two
/// suites is ever enabled, and a runner that never runs loads no model.
private let compactionEvalFullDatasetRunner = CompactionEvalRealSubjectRunner(seeds: compactionEvalSeeds)

/// Builds a gated tier's evaluation: the runner's own seeds folded with the
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

/// The mean `FactRetention` a gated tier's samples must reach.
///
/// compaction_plan.md §5's own bar, and the same value both tiers are held to —
/// the tiers differ in which seeds they measure, never in how well those seeds
/// have to do.
private let compactionEvalFactRetentionFloor = 0.9

/// Prints one tier's per-sample evidence, then asserts its mean
/// `FactRetention`.
///
/// Shared by both tiers so the two can never drift into measuring the same
/// metric two ways.
///
/// - Parameter runner: The tier's runner, holding the evidence its samples
///   recorded and the seed set that evidence is read against — so a run the
///   time limit cut short states the seeds it never reached.
private func expectFactRetention(of runner: CompactionEvalRealSubjectRunner) async {
    // Printed before the assertion so a run that misses the bar still
    // leaves the evidence behind: the mean alone cannot say whether a
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

    let result = EvaluationContext.current.result
    #expect(
        result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= compactionEvalFactRetentionFloor)
}

/// The DEFAULT gated real-model eval (compaction_plan.md §5's
/// `@Test(.evaluates(...))` sketch): folds each seed of
/// ``compactionEvalRepresentativeSeeds`` with the router's default compaction
/// prompt, resumes a session over each result, asks its question, and asserts
/// mean `FactRetention` over the subset is at least
/// ``compactionEvalFactRetentionFloor``.
///
/// Runtime-gated on `FM_ROUTER_INTEGRATION_TESTS`, exactly like every other
/// real-model suite in this repository — never runs on a network/GPU-less
/// box. The target itself, and this file's hermetic tests above, always build
/// and run.
///
/// It measures a subset rather than the whole dataset because the whole dataset
/// does not fit a limit anyone runs by habit — see
/// ``compactionEvalRepresentativeSubsetIDs`` for what the subset carries and
/// ``compactionEvalSubsetTimeLimitMinutes`` for the measurement behind its
/// limit. ``CompactionEvalFullDatasetIntegrationTests`` is the whole-dataset
/// tier, and this suite steps aside while that one is opted in.
///
/// This suite was long described here as blocked by an MLX `default.metallib`
/// load failure that no gated suite in this repository could get past. That
/// was wrong: the failure was a resource-colocation bug in `swift test`'s
/// binary layout, which ``MetalLibraryTestBootstrap`` now fixes from inside
/// ``GatedEvalResidencyTrait``, this suite's own trait.
///
/// ``GatedEvalResidencyTrait`` holds this suite's real model exclusive against
/// every other gated eval suite and evicts it when the suite ends, and
/// ``compactionEvalSubsetTimeLimitMinutes`` bounds a hung real-model load — see
/// ``GatedEvalSerialGate`` for why the target needs both.
@Suite(
    .enabled(if: compactionEvalsIntegrationEnabled && !compactionEvalsFullDatasetEnabled),
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
/// Gated on `FM_ROUTER_INTEGRATION_TESTS` and on
/// `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` together, so an ordinary gated run
/// never pays for it. Its dataset is a superset of the default tier's, and its
/// limit is ``compactionEvalFullDatasetTimeLimitMinutes``.
///
/// Named so it does not carry `CompactionEvaluationIntegrationTests` as a
/// substring: `swift test --filter` takes a regular expression, and a name that
/// contained the default tier's would make the everyday targeted command select
/// both tiers.
@Suite(
    .enabled(if: compactionEvalsIntegrationEnabled && compactionEvalsFullDatasetEnabled),
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
