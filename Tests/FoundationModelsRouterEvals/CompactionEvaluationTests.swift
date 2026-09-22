import Evaluations
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// The counter every hermetic test in this file counts with: one token per
/// character, the rule ``CharacterTokenCounter`` states for a scripted
/// backend. A gated tier counts with the loaded model's own counter instead,
/// so a size a test in this file states is in characters.
private let compactionEvalCounter = CharacterTokenCounter()

/// The output ceiling a recorded summarizer call states in the report tests
/// of this file.
///
/// A call's ceiling is the room its window leaves after its input, so no call
/// of the gated tier gets more than ``CompactionEvalRealModel/context``, the
/// window that tier loads its model at. The tests only read the value back
/// from a rendered line, so they use that upper end.
private let compactionEvalRecordedCallCeiling = CompactionEvalRealModel.context

// MARK: - Hermetic wiring (plain `swift test`, no real inference)

/// Hermetic proof that the evals target's wiring is correct: the dataset
/// loads every hand-written fixture, `subject(from:)` runs against a fake
/// model with no real inference, and pointing the same evaluation at two
/// different `CompactionPrompt`s yields per-prompt attributable outcomes —
/// exactly the acceptance criteria that do not need a real model to verify.
@Suite("CompactionEvaluation hermetic wiring")
struct CompactionEvaluationHermeticTests {
    @Test("the dataset stream carries one sample for every hand-written fixture")
    func datasetStreamCarriesEveryFixture() async throws {
        // The wiring property, and not the dataset's SIZE. This asked for at
        // least 20 samples while compaction_plan.md §5 asked the dataset for 20
        // to 30 fixtures; task ^k0d30s4 cut it to the seven the one gated tier
        // compacts, so a floor of 20 measured a requirement that no longer stands.
        // What the stream still owes is every fixture, under its own id:
        // `CompactionEvalRepresentativeSubsetTests` states how many there are
        // and what they carry between them.
        let evaluation = CompactionEvaluation { _, _, _, _ in
            ("unused", 0, 0, [])
        }

        var streamedIDs: [String] = []
        for try await sample in evaluation.dataset.stream {
            streamedIDs.append(try #require(sample.expected).seedID)
        }
        #expect(
            streamedIDs.sorted() == compactionEvalFixtureSpecs.map(\.id).sorted(),
            "the dataset stream carried \(streamedIDs.sorted())")
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
            return ("the fake answer", 500, 50, [Summarization.stageName])
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
        #expect(subject.value.stagesApplied == [Summarization.stageName])
        #expect(subject.value.plantedFact == expected.plantedFact)
        #expect(subject.value.factKeyPhrase == expected.factKeyPhrase)
        #expect(!capturedEntries.isEmpty)
        #expect(capturedQuestion == seed.question)
    }

    @Test("the default budget makes every fixture's compaction call the summarizer once and apply the summary")
    func defaultBudgetForcesSummarizationStage() async throws {
        // A hermetic proof of `compactionEvalDefaultBudget`'s own claim: every
        // seed is over its target, and the target leaves room for a summary
        // after the instructions. So `Compactor.compact` makes its one
        // summarizer call on every seed. It does not stop with the context
        // unchanged, and it does not report `.targetLeavesNoRoomForSummary`.
        // A seed that stopped there would leave no summary entry for
        // `FactRetention` to check. The test uses the real `Compactor`
        // directly (not `CompactionEvaluation`) with a trivial fake
        // summarizer, so it makes no real inference.
        //
        // The budget is read from the same constant the evaluation itself
        // defaults to, never restated as a literal here: a copy would let the
        // two drift, and this assertion's whole job is to fail when the value
        // stops forcing the call.
        struct FakeSummarizer: CompactionSummarizer {
            func summarize(_ prompt: String, maxTokens: Int) async throws -> String { "fake summary" }
        }

        try await Self.expectEverySeedCompactsThroughSummarization(
            with: FakeSummarizer(), answering: "a trivial summary")
    }

    @Test("every seed's compaction is applied, not discarded, against a summarizer that fills the size the prompt states")
    func everySeedCompactionSurvivesARealisticSummary() async throws {
        // The assertion above proves the budget carries every seed INTO the
        // summarizer call. It cannot prove that the compaction kept the
        // summary, because its summarizer answers in two words: a summary of
        // 12 bytes shrinks any transcript.
        //
        // `Compactor.compact` discards a summary that left the transcript no
        // smaller, and against a real model that is what these seeds used to
        // get: the gated run of 2026-08-17 reported `summarizerCalls=1` with an
        // empty stage list on 8 of the 9 samples that completed. The
        // summarizer answered, the compaction discarded the summary, so the
        // resumed session answered from the original turns and the dataset
        // measured nothing about compaction at all.
        //
        // So the summarizer here answers with the whole size the prompt
        // states (see `StatedSizeSummarizer`): the largest answer a
        // summarizer that keeps to the stated size writes. This assertion
        // fails the moment a seed stops compacting, under a plain
        // `swift test` and not deep into a gated run.
        // `CompactionEvalSeedSizingTests` states the arithmetic behind it.
        try await Self.expectEverySeedCompactsThroughSummarization(
            with: StatedSizeSummarizer(),
            answering: "a summary that fills the stated size"
        )
    }

    /// Compacts every seed with `summarizer` against ``compactionEvalDefaultBudget``
    /// and requires the one summarizer call to have run and its summary to be
    /// APPLIED.
    ///
    /// The budget is read from the same constant the evaluation itself defaults
    /// to, never restated as a literal: a copy would let the two drift, and
    /// these assertions exist to fail when that value stops forcing the compaction.
    ///
    /// The summarizer slot's window is ``CompactionEvalRealModel/context``, the
    /// window the gated tier loads its model at, so the hermetic call runs in
    /// the window the gated call runs in.
    ///
    /// - Parameters:
    ///   - summarizer: The summarizer the compaction calls.
    ///   - description: How the summarizer answers, named in the failure message
    ///     so a red run says which of the two callers below found the seed.
    /// - Throws: Whatever the compaction throws.
    private static func expectEverySeedCompactsThroughSummarization(
        with summarizer: any CompactionSummarizer,
        answering description: String
    ) async throws {
        let budget = compactionEvalDefaultBudget
        for seed in compactionEvalSeeds {
            let (_, result) = try await Compactor.compact(
                Transcript(entries: seed.entries),
                budget: budget,
                counter: compactionEvalCounter,
                summarizers: [
                    CompactionSummarizerSlot(
                        tier: .ownModel, summarizer: summarizer,
                        windowTokens: CompactionEvalRealModel.context, model: nil)
                ]
            )
            #expect(
                result.stagesApplied == [Summarization.stageName],
                "seed \(seed.id) did not apply a summary against \(description): stagesApplied was \(result.stagesApplied), shortfall was \(String(describing: result.shortfall))"
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

    @Test("no seed transcript repeats an assistant reply, so no summarizer input repeats one string")
    func noSeedRepeatsAnAssistantReply() {
        // The gated run of 2026-08-09 classified 18 of 19 `factRetention`
        // failures as `answerMissedFactSummaryCarriedIt`, and every one of the
        // 18 answered with the literal string `"Noted."` — which was, at the
        // time, the single canned reply every statement turn of every fixture
        // carried. That run predates task ^pke18c2: the compaction then kept
        // the newest turns word for word, so each resumed context ended in 4-7
        // consecutive `question -> "Noted."` pairs, and the model completed
        // that pattern and did not read a summary. The one call of today
        // summarizes every turn, so a repeated reply now repeats one line in
        // the summarizer's input, and a small model writes such a line back
        // into its summary (see `CompactionSmokeIntegrationTests`). A dataset
        // that repeats one reply cannot tell compaction quality apart from
        // pattern completion, so uniqueness is the property the fixtures must
        // hold.
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
        // planted fact ever surviving the compaction — the dataset would then measure
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

    @Test("every seed opens with the measured recall instructions, so the resumed session answers instead of refusing")
    func everySeedOpensWithTheRecallInstructions() {
        // The compaction keeps the `.instructions` entry, so the resumed session
        // answers the seed's question under this header. The gated runs of
        // 2026-08-19 (task ^e814b60) measured three other registers against
        // it: the bare helpful persona refused facts its own summary stated,
        // and the two registers without the summary-reliability clause
        // answered with invented values instead — see
        // ``compactionEvalRecallInstructions`` for every run's counts. This
        // pins the dataset to the one register those measurements chose.
        for seed in compactionEvalSeeds {
            guard case .instructions(let instructions) = seed.entries.first else {
                Issue.record("seed \(seed.id) does not open with an instructions entry")
                continue
            }
            #expect(
                Summarization.text(of: instructions.segments) == compactionEvalRecallInstructions,
                "seed \(seed.id) does not open with the measured recall instructions"
            )
        }
    }

    /// Every assistant reply in `seed`'s built transcript, in order — the text
    /// content of each `.response` entry.
    ///
    /// Flattened by ``Summarization/text(of:)``, the production function a compaction
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
    /// summarizer reading the compacted span is shown.
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
/// failing `FactRetention` sample to the right side of the compaction.
///
/// The gated eval's mean is one number over the whole dataset, so a run that
/// misses the bar says nothing about *where* each failing sample lost its
/// fact. These tests pin the three distinguishable places apart — the answer
/// lost a fact the summary carried, the compaction itself dropped it, or no summary
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

    /// One of the two probe seeds, as a share.
    ///
    /// The value `CompactionEvalFactRetentionReport/share(of:over:)` must answer
    /// for one sample in two, and the case that separates a real division from a
    /// guard answering zero whatever it is given.
    private static let halfShare = 0.5

    /// Builds one recorded summarizer call answering `answer` at
    /// ``compactionEvalRecordedCallCeiling``.
    ///
    /// - Parameter answer: The text the summarizer answered.
    /// - Returns: The recorded call.
    private static func makeSummarizerCall(answering answer: String) -> CompactionEvalSummarizerCall {
        CompactionEvalSummarizerCall(maxTokens: compactionEvalRecordedCallCeiling, answer: answer)
    }

    /// Builds a recorded sample against ``seed``'s question.
    ///
    /// The recorded call answers exactly `summary`, which is what a compaction that
    /// was applied really records: the stored summary is the summarizer's own
    /// last answer.
    ///
    /// - Parameters:
    ///   - summary: The compaction's summary text, or `nil` for a compaction that produced
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
            stagesApplied: [Summarization.stageName],
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

    @Test("a summary that dropped the key phrase is a compaction failure")
    func summaryWithoutKeyPhraseIsACompactionFailure() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "2. Constraints & decisions — the team discussed a vault.",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .summaryLostFact)
    }

    @Test("a compaction that produced no summary is its own class")
    func absentSummaryIsItsOwnClass() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: nil,
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .compactionProducedNoSummary)
    }

    @Test("a summary with no text is a compaction failure, not a summary that lost the fact")
    func emptySummaryIsACompactionFailure() {
        // The gated run of 2026-08-17 recorded `Optional("")` on 19 of 19 seeds:
        // the compaction ran, the summarizer answered, and the answer held no
        // characters. A `nil` guard alone filed every one of them under
        // `summaryLostFact`, which reads as a summary that forgot the fact.
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .compactionProducedNoSummary)
    }

    @Test("a summary of whitespace alone is a compaction failure too: it carries no summary either")
    func whitespaceOnlySummaryIsACompactionFailure() {
        let classification = CompactionEvalFactRetentionClass.classify(
            summary: "  \n\t  ",
            answer: "I do not have that information.",
            factKeyPhrase: Self.seed.factKeyPhrase
        )
        #expect(classification == .compactionProducedNoSummary)
    }

    @Test("the rendered table names an empty summary, so a compaction that stored no text is legible in the log")
    func renderedTableNamesAnEmptySummary() throws {
        // The printer wrote `summary=` with nothing after it, which reads as a
        // truncated line rather than as the measurement it is.
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "", answer: "Noted.")],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        let table = CompactionEvalFactRetentionReport.lines(
            of: findings, expecting: [Self.seed], counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("summary=<empty>"))
        #expect(table.contains(CompactionEvalFactRetentionClass.compactionProducedNoSummary.rawValue))
    }

    @Test("the rendered table names a discarded compaction, so a compaction that ran and was thrown away is legible as one")
    func renderedTableNamesADiscardedCompaction() throws {
        // `Compactor.compact` reports a compaction it discarded through the same
        // shortfall exit an uncompacted transcript takes: no summary, no stage
        // applied. The table wrote `<none>` for it, which is what a compaction that
        // never ran gets, so the gated run of 2026-08-17 printed 8 samples whose
        // summarizer had answered and whose compaction had been thrown away as though
        // no stage had ever run.
        let discarded = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "I do not have that information.",
            stagesApplied: [],
            summarizerCalls: [Self.makeSummarizerCall(answering: "a summary the pipeline threw away")]
        )
        #expect(discarded.compactionDiscarded)
        let table = try Self.renderedTable(for: discarded)
        #expect(table.contains("summary=\(CompactionEvalFactRetentionReport.discardedSummaryMarker)"))
        #expect(!table.contains("summary=\(CompactionEvalFactRetentionReport.absentSummaryMarker)"))
    }

    @Test("a compaction that never ran still renders as absent, so the discarded marker names only a discarded compaction")
    func renderedTableStillNamesACompactionThatNeverRan() throws {
        // The other half of the same property. This transcript was already
        // under its target, so the compaction called no summarizer and there
        // is no summary to have discarded.
        let neverRan = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "I do not have that information.",
            stagesApplied: [],
            summarizerCalls: []
        )
        #expect(!neverRan.compactionDiscarded)
        let table = try Self.renderedTable(for: neverRan)
        #expect(table.contains("summary=\(CompactionEvalFactRetentionReport.absentSummaryMarker)"))
        #expect(!table.contains("summary=\(CompactionEvalFactRetentionReport.discardedSummaryMarker)"))
        // No summarizer ever answered, so there is no discarded summary to
        // measure and the stanza states none.
        #expect(!table.contains("  discarded="))
    }

    @Test("a discarded compaction states how large the summary that lost was, beside the span it was to replace")
    func renderedTableStatesTheDiscardedSummarysSize() throws {
        // `<discarded>` alone says a compaction ran and was thrown away. It does not
        // say by how much, and on the shortfall path `CompactionResult.summary`
        // is `nil`, so the size of the summary that lost was recorded nowhere at
        // all: the gated run of 2026-08-17 printed `summary=<discarded>` on 7 of
        // 7 seeds and left the next run unable to tell a compaction that missed by a
        // few percent from one that missed by a multiple.
        //
        // Read against a real dataset seed rather than the empty probe seeds
        // above, so the span the line states is a span a compaction really replaces.
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
            of: try CompactionEvalFactRetentionReport.findings(
                for: [discarded], seeds: [seed], counter: compactionEvalCounter),
            expecting: [seed],
            counter: compactionEvalCounter
        )
        .joined(separator: "\n")

        let spanTokens = try seed.compactableSpanTokens(counter: compactionEvalCounter)
        #expect(table.contains("discarded=\(answer.utf8.count) bytes"))
        #expect(table.contains("summaryTokens=\(compactionEvalCounter.count(answer))"))
        #expect(table.contains("spanTokens=\(spanTokens)"))
        #expect(table.contains("ceiling=\(compactionEvalRecordedCallCeiling)"))
        // The text itself, bounded: enough of it to read what the model wrote,
        // and never the whole of a summary that ran to thousands of bytes.
        #expect(table.contains(CompactionEvalFactRetentionReport.discardedSummaryTruncationMarker))
        #expect(!table.contains(answer))
    }

    /// Renders the report table for one recorded sample against ``seed``,
    /// counted with ``compactionEvalCounter``.
    ///
    /// - Parameter diagnostic: The sample's recorded evidence.
    /// - Returns: The rendered table, one line per newline.
    /// - Throws: What the counter throws.
    private static func renderedTable(for diagnostic: CompactionEvalSampleDiagnostic) throws -> String {
        CompactionEvalFactRetentionReport.lines(
            of: try CompactionEvalFactRetentionReport.findings(
                for: [diagnostic], seeds: [seed], counter: compactionEvalCounter),
            expecting: [seed],
            counter: compactionEvalCounter
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
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        let finding = try #require(findings.first)
        #expect(finding.seedID == Self.seed.id)
        #expect(finding.plantedFact == Self.seed.plantedFact)
        #expect(finding.factKeyPhrase == Self.seed.factKeyPhrase)
        #expect(finding.factInSummary == true)
        #expect(finding.classification == .answerMissedFactSummaryCarriedIt)
    }

    @Test("a recorded sample matching no seed is still classified, so no sample is dropped")
    func unmatchedSampleIsStillClassified() throws {
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "anything", answer: "anything", question: "a question no seed asks")],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        #expect(findings.count == 1)
        #expect(findings.first?.classification == .unrecognizedSample)
    }

    @Test("the counts name every class and sum to the number of recorded samples")
    func countsCoverEveryClassAndSumToTheSampleCount() throws {
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "Noted."),
                Self.makeDiagnostic(summary: "no code here", answer: "Noted."),
                Self.makeDiagnostic(summary: nil, answer: "Noted."),
            ],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        let counts = CompactionEvalFactRetentionReport.counts(of: findings)
        #expect(counts.count == CompactionEvalFactRetentionClass.allCases.count)
        #expect(counts[.retained] == 1)
        #expect(counts[.answerMissedFactSummaryCarriedIt] == 1)
        #expect(counts[.summaryLostFact] == 1)
        #expect(counts[.compactionProducedNoSummary] == 1)
        #expect(counts[.unrecognizedSample] == 0)
        #expect(counts.values.reduce(0, +) == findings.count)
    }

    @Test("the rendered table states each sample's fact, question, answer and summary")
    func renderedTableStatesEverySamplesEvidence() throws {
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "The vault code is CRIMSON-77.", answer: "Noted.")],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        let table = CompactionEvalFactRetentionReport.lines(
            of: findings, expecting: [Self.seed], counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains(Self.seed.id))
        #expect(table.contains(Self.seed.plantedFact))
        #expect(table.contains(Self.seed.question))
        #expect(table.contains("The vault code is CRIMSON-77."))
        #expect(table.contains("answer=Noted."))
        #expect(table.contains("factInSummary=true"))
        #expect(table.contains("compacted=true"))
        #expect(table.contains(CompactionEvalFactRetentionClass.answerMissedFactSummaryCarriedIt.rawValue))
    }

    @Test("a stage list without Summarization records the sample as uncompacted")
    func stagesWithoutSummarizationAreNotCompacted() {
        let uncompacted = CompactionEvalSampleDiagnostic(
            question: Self.seed.question,
            summary: nil,
            answer: "Noted.",
            stagesApplied: [],
            summarizerCalls: []
        )
        #expect(uncompacted.compacted == false)
        #expect(Self.makeDiagnostic(summary: "s", answer: "a").compacted == true)
    }

    @Test("every seed's question is unique, so a recorded sample joins back to exactly one seed")
    func everySeedQuestionIsUnique() {
        let questions = compactionEvalSeeds.map(\.question)
        #expect(Set(questions).count == questions.count)
    }

    @Test("the table heads itself with the seeds it measured out of the seeds it was given")
    func tableStatesHowManyOfTheTiersSeedsItMeasured() throws {
        // A run the suite time limit cut short recorded a sample for some of its
        // seeds and none for the rest. The head counted the samples alone —
        // "9 samples" — which reads as a whole measurement of a nine-seed tier
        // rather than as a third of a 24-seed one (task ^fz49qds).
        let table = CompactionEvalFactRetentionReport.lines(
            of: try CompactionEvalFactRetentionReport.findings(
                for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
                seeds: Self.bothSeeds,
                counter: compactionEvalCounter
            ),
            expecting: Self.bothSeeds,
            counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("1 of 2 seeds measured"))
    }

    @Test("a run cut short names the seeds it never reached, so a partial table cannot read as a whole one")
    func runCutShortNamesTheSeedsItNeverReached() throws {
        // The evidence a run leaves behind is the samples that ran. Nothing in
        // the table said the rest never ran, so the `counts:` tally summed to
        // the samples present and read as a clean sheet over the whole dataset.
        let table = CompactionEvalFactRetentionReport.lines(
            of: try CompactionEvalFactRetentionReport.findings(
                for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
                seeds: Self.bothSeeds,
                counter: compactionEvalCounter
            ),
            expecting: Self.bothSeeds,
            counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("unreached: 1 of 2 seeds never ran"))
        #expect(table.contains(Self.unreachedSeed.id))
        #expect(!table.contains(CompactionEvalFactRetentionReport.everySeedReachedMarker))
    }

    @Test("a run that reached every seed says so, so the absence of a name is stated rather than inferred")
    func completeRunStatesThatEverySeedRan() throws {
        // The other half of the same property. A table with no unreached line at
        // all would leave a reader unable to tell a complete run from a printer
        // that never states one.
        let table = CompactionEvalFactRetentionReport.lines(
            of: try CompactionEvalFactRetentionReport.findings(
                for: [
                    Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                    Self.makeDiagnostic(
                        summary: "PORT-6543", answer: "It is PORT-6543.", question: Self.unreachedSeed.question),
                ],
                seeds: Self.bothSeeds,
                counter: compactionEvalCounter
            ),
            expecting: Self.bothSeeds,
            counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("unreached: \(CompactionEvalFactRetentionReport.everySeedReachedMarker)"))
        #expect(table.contains("2 of 2 seeds measured"))
    }

    @Test("an unreached seed is named by id, and a reached one is not")
    func unreachedSeedIDsNameOnlyTheSeedsNoSampleCovered() throws {
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77.")],
            seeds: Self.bothSeeds,
            counter: compactionEvalCounter
        )
        #expect(
            CompactionEvalFactRetentionReport.unreachedSeedIDs(in: findings, expecting: Self.bothSeeds)
                == [Self.unreachedSeed.id])
    }

    @Test("the table states what the compactions carried beside what the answers carried")
    func tableStatesTheCompactionShareBesideTheAnswerShare() throws {
        // The two are different measurements, and the tier used to report the
        // second alone. The gated run of 2026-08-18 measured 4 of 6 summaries
        // carrying the fact against 2 of 6 answers, and one mean hid that
        // (task ^xscp198).
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                Self.makeDiagnostic(
                    summary: "PORT-6543", answer: "Noted.", question: Self.unreachedSeed.question),
            ],
            seeds: Self.bothSeeds,
            counter: compactionEvalCounter
        )
        #expect(CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings) == findings.count)
        let table = CompactionEvalFactRetentionReport.lines(
            of: findings, expecting: Self.bothSeeds, counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("retention: summary=2 of 2 answer=1 of 2"))
    }

    @Test("a compaction that produced no summary counts against the compaction share, because it carries nothing")
    func compactionThatProducedNoSummaryCountsAgainstTheCompactionShare() throws {
        let findings = try CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: nil, answer: "I do not have that information.")],
            seeds: [Self.seed],
            counter: compactionEvalCounter
        )
        #expect(CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings) == 0)
        let table = CompactionEvalFactRetentionReport.lines(
            of: findings, expecting: [Self.seed], counter: compactionEvalCounter
        )
        .joined(separator: "\n")
        #expect(table.contains("retention: summary=0 of 1 answer=0 of 1"))
    }

    @Test("a share over no samples is zero, so a run that recorded nothing never reads as a clean sheet")
    func shareOverNoSamplesIsZero() {
        #expect(CompactionEvalFactRetentionReport.share(of: 0, over: 0) == 0)
        // And a real division still divides. One of the two probe seeds is a
        // half, which a guard answering zero for every input would miss.
        #expect(
            CompactionEvalFactRetentionReport.share(of: 1, over: Self.bothSeeds.count) == Self.halfShare)
    }
}

// MARK: - Hermetic progress-line rendering

/// Hermetic proof that a gated tier leaves a live trail naming where a run
/// stopped (task ^h2xxsse).
///
/// ``CompactionEvalRealSubjectRunner`` records a sample only once its compaction AND
/// its answering turn have both finished, and ``expectFactRetention(of:)``
/// prints its table once at the very end. So a run the suite time limit cut
/// short reported one bit — "not finished". The gated run of 2026-08-18 hit the
/// subset tier's own 1800-second limit with 0 of 7 seeds measured, against two
/// earlier runs of the same tier that measured 7 of 7 in 1644.7 s and 1685.9 s,
/// and nothing it printed could say whether the model load, one compaction, or one
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
        ordinal: sampleOrdinal, total: tierSeedCount, fixture: .seed, fixtureID: sampleSeedID)

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
            .compaction, sample: Self.label, elapsedSeconds: Self.elapsedSeconds)

        #expect(line.contains("\(CompactionEvalProgressStep.compaction.rawValue) \(CompactionEvalProgressLog.startedMarker)"))
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
            .compaction, sample: Self.label, elapsedSeconds: nil)

        #expect(line.contains("sample=\(Self.sampleOrdinal)/\(Self.tierSeedCount)"))
        #expect(line.contains("seed=\(Self.sampleSeedID)"))
    }

    @Test("a sample's first step states no elapsed clause, rather than a zero that reads as a measurement")
    func firstStepOfASampleStatesNoElapsedClause() {
        let first = CompactionEvalProgressLog.makeStepStartedLine(
            .compaction, sample: Self.label, elapsedSeconds: nil)
        let later = CompactionEvalProgressLog.makeStepStartedLine(
            .answer, sample: Self.label, elapsedSeconds: Self.elapsedSeconds)

        #expect(!first.contains("elapsed="))
        #expect(later.contains("elapsed=\(CompactionEvalProgressLog.makeSecondsText(Self.elapsedSeconds))"))
    }

    @Test("a label built from a seed's question names that seed")
    func labelBuiltFromASeedsQuestionNamesThatSeed() throws {
        let seeds = compactionEvalRepresentativeSeeds
        let seed = try #require(seeds.last)
        let label = CompactionEvalSampleLabel(
            ordinal: seeds.count,
            of: seeds.count,
            fixture: .seed,
            id: CompactionEvalSeed.keyedByQuestion(seeds)[seed.question]?.id
        )

        #expect(label.fixtureID == seed.id)
        #expect(label.ordinal == seeds.count)
        #expect(label.total == seeds.count)
        #expect(label.rendered.contains("seed=\(seed.id)"))
    }

    @Test("a label whose question matches no seed is still named, by the report's own marker")
    func labelWhoseQuestionMatchesNoSeedIsStillNamed() {
        let seeds = compactionEvalRepresentativeSeeds
        let label = CompactionEvalSampleLabel(
            ordinal: 1,
            of: seeds.count,
            fixture: .seed,
            id: CompactionEvalSeed.keyedByQuestion(seeds)["a question no seed asks"]?.id
        )

        #expect(label.fixtureID == CompactionEvalFactRetentionReport.unmatchedSeedID)
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

    @Test("a compaction's returned line states what its summarizer produced")
    func compactionReturnedLineStatesWhatTheSummarizerProduced() {
        let summary = "2. Stated facts — the staging database listens on port 6543."
        let detail = CompactionEvalProgressLog.makeCompactionDetail(
            stagesApplied: [Summarization.stageName],
            summarizerCalls: [
                CompactionEvalSummarizerCall(maxTokens: compactionEvalRecordedCallCeiling, answer: summary)
            ]
        )

        #expect(detail.contains("stages=\(Summarization.stageName)"))
        #expect(detail.contains("summarizerCalls=1"))
        #expect(detail.contains("summarizerBytes=\(summary.utf8.count)"))
    }

    @Test("a compaction that called no summarizer states zero bytes rather than nothing")
    func compactionThatCalledNoSummarizerStatesZeroBytes() {
        let detail = CompactionEvalProgressLog.makeCompactionDetail(
            stagesApplied: [], summarizerCalls: [])

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

/// Ungated proof that every seed fits the one summarizer call a compaction
/// makes against ``compactionEvalDefaultBudget`` (tasks ^vjf3mdm, ^pke18c2).
///
/// `CompactionEvaluationHermeticTests/everySeedCompactionSurvivesARealisticSummary`
/// is the mechanical gate: it compacts every seed and requires the summary to
/// be applied. This suite states the arithmetic that gate rests on, so a seed
/// or a budget that drifts fails with a number and not with "the compaction was
/// discarded".
///
/// The compaction states a size for the summary: the target less the
/// instructions. The new snapshot is the instructions and the summary, so a
/// summary that keeps to the stated size makes a snapshot of about the
/// target. The snapshot is smaller than the seed exactly when the seed is over
/// the target, so one bound holds both "the call runs" and "the summary
/// shrinks the context".
///
/// Each bound is held under two counters. ``compactionEvalCounter`` counts one
/// token for each character, and the gated tier counts with the tokenizer of
/// ``CompactionEvalRealModel``. A fixture sized in one unit and measured in
/// another is what `CompactionRoundTripIntegrationTests` missed twice (tasks
/// 5m97h14 and ^wnj3ka3). The tokenizer count is not available without the
/// model, so this suite converts characters to tokens at
/// ``compactionEvalMeasuredBytesPerToken``. That is the largest measured rate,
/// so the converted count is the smallest the tokenizer can give.
@Suite("CompactionEvaluation seed sizing (ungated)")
struct CompactionEvalSeedSizingTests {
    /// The target of ``compactionEvalDefaultBudget``, in tokens.
    private static let targetTokens = compactionEvalDefaultBudget.targetTokens

    /// The size, in tokens, the compaction states for the summary of `seed`
    /// under ``compactionEvalCounter``: the target less the instructions.
    ///
    /// - Parameter seed: The seed to read.
    /// - Returns: The stated size.
    /// - Throws: What the counter throws.
    private static func statedSummaryTokens(of seed: CompactionEvalSeed) throws -> Int {
        let instructions = seed.entries.filter {
            if case .instructions = $0 { return true }
            return false
        }
        return targetTokens - (try compactionEvalCounter.count(Transcript(entries: instructions)))
    }

    @Test("every seed is over the default budget's target under both counters, so its compaction makes the one call")
    func everySeedIsOverTheTarget() throws {
        // Under the target, the compaction leaves the context as it is and
        // calls no summarizer, so the sample measures nothing. Over it, the
        // summary that keeps to the stated size makes a smaller snapshot.
        for seed in compactionEvalSeeds {
            let characters = try compactionEvalCounter.count(Transcript(entries: seed.entries))
            let fewestModelTokens = Double(characters) / compactionEvalMeasuredBytesPerToken
            #expect(
                characters > Self.targetTokens,
                "seed \(seed.id) counts \(characters) characters, not over the target's \(Self.targetTokens)"
            )
            #expect(
                fewestModelTokens > Double(Self.targetTokens),
                "seed \(seed.id) converts to \(fewestModelTokens) model tokens, not over the target's \(Self.targetTokens)"
            )
        }
    }

    @Test("the target leaves room for a summary after the instructions under both counters")
    func targetLeavesRoomAfterTheInstructions() throws {
        // A stated size of zero or less stops the compaction with
        // `.targetLeavesNoRoomForSummary` and no call. The character counter
        // is the strict side of this bound: it counts the instructions as more
        // tokens than the tokenizer does, so it leaves the summary less room.
        // A stated size over zero under it is over zero under the tokenizer.
        for seed in compactionEvalSeeds {
            let stated = try Self.statedSummaryTokens(of: seed)
            #expect(
                stated > 0,
                "seed \(seed.id) gets a stated size of \(stated) tokens after its instructions, so the target leaves no room"
            )
        }
    }

    @Test("every seed's call fits the window the gated tier loads its model at, with the stated size to spare")
    func everySeedsCallFitsTheGatedWindow() throws {
        // The call's ceiling is the stated size, capped at the room the
        // window leaves after the input. A room under the stated size cuts a
        // summary that keeps to it. The character counter is the strict side
        // here too: it counts the input as more tokens than the tokenizer does.
        let windowTokens = CompactionEvalRealModel.context
        for seed in compactionEvalSeeds {
            let stated = try Self.statedSummaryTokens(of: seed)
            let prompt = Summarization.assembledPrompt(
                .default, allowedSummaryTokens: stated, content: Summarization.render(seed.entries))
            let room = windowTokens - compactionEvalCounter.count(prompt)
            #expect(
                room >= stated,
                "seed \(seed.id)'s call leaves a room of \(room) tokens in a window of \(windowTokens), under the stated size of \(stated)"
            )
        }
    }
}

// MARK: - Ungated gated-subset coverage

/// Ungated proof that the seeds the gated tier measures still span every
/// property this dataset is built to vary (task ^fz49qds).
///
/// A tier of seven seeds is only worth running when those seven are
/// representative. "Representative" is a property of the fixtures, so it is
/// checked against the fixtures rather than argued for in a comment: an edit
/// that drops the last tool-traffic seed, or gives every seed the same number
/// of turns after its facts, fails under a plain `swift test` instead of silently narrowing what
/// the gated tier measures.
///
/// Each bar below is ABSOLUTE — what these seven must carry, stated here — and
/// deliberately not read back off ``compactionEvalFixtureSpecs``. Three of them
/// were read off the dataset while a second gated tier compacted a wider one, and
/// task ^k0d30s4 cut the dataset to exactly the seeds this tier measures. A bar
/// read off the dataset now compares the dataset with itself and passes
/// whatever the dataset holds, so the bars that could go trivial are stated as
/// values instead. The two that already read the subset alone — the delivery
/// bar and the probed-position bar — are unchanged.
@Suite("CompactionEvaluation gated subset coverage (ungated)")
struct CompactionEvalRepresentativeSubsetTests {
    /// How many seeds the subset holds.
    ///
    /// ONE size, and not a band. `CompactionEvalTierBarTests` holds
    /// ``compactionEvalSubsetTimeLimitMinutes`` to the next whole minute above
    /// the bound its own seed count derives, from both sides. At eight seeds
    /// the derived bound rises to 2.14 minutes and the 2 the limit states no
    /// longer covers it, so the upper side of that binding still refuses a
    /// larger subset.
    ///
    /// The lower side no longer refuses one. At six seeds the bound falls to
    /// 1.61 minutes, which 2 still covers and is still the next whole minute
    /// above — the two sides only pinned one seed count while the tier drove
    /// the 30B model at 42 minutes, and tasks ^6ssbakk and ^m03heaa replaced
    /// that rate with the canary's. So this literal, and
    /// `subsetHoldsTheSeedCountItsTimeLimitWasMeasuredAgainst` below, are what
    /// hold a SMALLER subset to account now.
    ///
    /// The size is stated once for that reason. The `6...8` band this replaced,
    /// and the `6...7` it first narrowed to, each permitted a size the limit
    /// binding refused at the time: a subset really moved to six seeds passed
    /// this test and failed
    /// `subsetTimeLimitIsTheNextWholeMinuteAboveItsBound`. Two tests that
    /// disagree about which sizes are legal state no property, so a subset moved
    /// to any other count fails here until the limit is measured again and
    /// edited with it (tasks ^6ssbakk, ^xscp198).
    ///
    /// Written as a literal rather than read back from
    /// ``compactionEvalRepresentativeSeeds``, so the test below compares two
    /// independent statements rather than a value with itself.
    private static let subsetSeedCount = 7

    /// The fixture specs the subset names, in dataset order.
    ///
    /// Read back out of ``compactionEvalFixtureSpecs`` because
    /// ``CompactionEvalSeed`` carries none of the properties this suite checks —
    /// the built seed keeps its entries, its planted fact and its question, and
    /// drops the fact count, the delivery and the count of turns after the facts.
    private static let subsetSpecs = compactionEvalFixtureSpecs.filter {
        compactionEvalRepresentativeSubsetIDs.contains($0.id)
    }

    /// Every head size the seven seeds must carry between them.
    ///
    /// A single-fact head gives the summarizer one thing to keep. A three-fact
    /// head makes it choose what to keep, which is the harder measurement, and
    /// seven single-fact heads would never make it. The two-fact head is the
    /// step between: it is the smallest head on which a summary can keep one
    /// planted fact and drop another.
    private static let requiredHeadSizes: Set<Int> = [1, 2, 3]

    /// The size of the largest head the subset carries, and the one head size
    /// whose probed positions this suite reads together with the size.
    private static let threeFactHeadSize = 3

    /// The positions the subset must probe a three-fact head at, read together
    /// with the head size rather than alone.
    ///
    /// The middle fact is the hardest fact for a summary to keep, because the
    /// summarizer must reach past a fact on each side of it. The last fact is
    /// the one the summary is written with freshest. The first of three is not
    /// required: it is the easiest of the three shapes, and the one- and
    /// two-fact heads of the subset probe index 0 already. Task ^k0d30s4's cut
    /// lost the middle position in silence, because
    /// `subsetProbesEveryPositionInTheHead` reads the position on its own and a
    /// two-fact head probed at index 1 satisfies it (task ^ghkxf3r).
    private static let requiredThreeFactProbedIndices: Set<Int> = [1, 2]

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

    @Test("the subset holds the one seed count its time limit was measured against")
    func subsetHoldsTheSeedCountItsTimeLimitWasMeasuredAgainst() {
        #expect(
            compactionEvalRepresentativeSeeds.count == Self.subsetSeedCount,
            """
            the gated subset holds \(compactionEvalRepresentativeSeeds.count) seeds, not the \
            \(Self.subsetSeedCount) its time limit was measured against
            """
        )
    }

    @Test("the subset carries a one-, a two- and a three-fact head, so a multi-fact compaction is measured")
    func subsetCarriesEveryRequiredHeadSize() {
        let subsetCounts = Set(Self.subsetSpecs.map(\.facts.count))
        #expect(
            subsetCounts == Self.requiredHeadSizes,
            "the gated subset carries head sizes \(subsetCounts.sorted())")
    }

    @Test("the subset carries both tool-traffic and plain-reply delivery")
    func subsetCarriesBothDeliveries() {
        // A fact delivered as tool traffic reaches the summarizer as a tool
        // call line and a tool output line, not as a user statement. A subset
        // of plain-reply seeds alone would never measure whether the one call
        // carries a fact out of tool output.
        let deliveries = Set(Self.subsetSpecs.map(\.probedFactViaTool))
        #expect(deliveries == [true, false], "the gated subset carries deliveries \(deliveries)")
    }

    @Test("the subset's count of turns after the facts varies, so the compaction is measured at more than one distance")
    func subsetVariesTheRecentTurnCount() {
        // The turns after the facts decide the size of the live context the
        // one call summarizes, and how far the probed fact sits from the end
        // of the conversation the summarizer reads. Seven seeds that all
        // carried the same number of those turns would measure the compaction
        // at one distance and read as coverage.
        let counts = Set(Self.subsetSpecs.map(\.recentTurnCount))
        #expect(
            counts.count > 1,
            "every seed of the gated subset carries \(counts.sorted()) turns after its facts, which is one count")
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

    @Test("the subset probes a three-fact head in the middle and at its end")
    func subsetProbesAThreeFactHeadInTheMiddleAndAtItsEnd() {
        // The head size and the probed position are read TOGETHER. Each bar
        // above reads one of the two on its own, so a subset whose three-fact
        // heads probed index 0 and index 2 alone passed every bar while no seed
        // measured the summary against the middle fact of a head. A middle
        // fact is the one a summarizer must reach past a fact on each side of.
        let probedIndices = Set(
            Self.subsetSpecs
                .filter { $0.facts.count == Self.threeFactHeadSize }
                .map(\.probedFactIndex))
        #expect(
            Self.requiredThreeFactProbedIndices.isSubset(of: probedIndices),
            "the gated subset probes its three-fact heads at \(probedIndices.sorted())"
        )
    }

    @Test("the subset probes a tool-delivered head at its first fact and after its first fact")
    func subsetProbesAToolDeliveredHeadAtAndAfterItsFirstFact() {
        // The delivery and the probed position are read TOGETHER.
        // The tool-traffic turn is the probed fact's own turn, and the one
        // call reads it as tool call and tool output lines. A subset whose
        // every tool-delivered head probed index 0 passed the delivery bar and
        // the position bar, and measured a tool-delivered fact at the start of
        // a head and never after it.
        let toolDeliveredIndices = Set(Self.subsetSpecs.filter(\.probedFactViaTool).map(\.probedFactIndex))
        #expect(
            toolDeliveredIndices.contains(0),
            "no tool-delivered head of the gated subset probes its first fact"
        )
        #expect(
            toolDeliveredIndices.contains { $0 > 0 },
            "no tool-delivered head of the gated subset probes a fact after its first"
        )
    }

    @Test("the subset probes a rule on the assistant's own later answers, so a compaction that drops a constraint is measured")
    func subsetProbesARuleOnLaterAnswers() {
        // An identifier can only be carried word for word, so a seed that probes
        // one measures whether the summary COPIED the fact. A rule the user set
        // on the assistant's later answers is the one kind whose loss is a harm
        // rather than a miss, and its probed phrase is an ordinary word a
        // summary that dropped the fact can replace with a plausible wrong one.
        // Task ^k0d30s4's cut lost the only such fixture, because no bar read
        // the kind of a fact (task ^rdsbf57).
        let kinds = Self.subsetSpecs.map(\.probedFactKind)
        #expect(
            kinds.contains(.ruleOnLaterAnswers),
            "the gated subset probes facts of kinds \(kinds), none a rule on the assistant's own later answers"
        )
    }
}

// MARK: - Ungated tier thresholds

/// Ungated proof that the gated tier's two thresholds — the wall clock it runs
/// under and the `FactRetention` bar it is held to — state the measurement they
/// rest on, and that the seed count can express that bar (tasks ^6ssbakk,
/// ^xscp198).
///
/// Both thresholds used to be prose alone. A limit stated 30 minutes against a
/// per-sample rate that had since risen, and a floor stated 0.9 against a seed
/// count that could only produce 0.857 or 1.0. Neither could be read off the
/// value, so neither failed when it stopped being true. These tests make each
/// one an arithmetic over values the eval measures, so a subset that outgrew its
/// limit, or a floor its seed count cannot express, fails a plain `swift test`.
@Suite("CompactionEvaluation tier thresholds (ungated)")
struct CompactionEvalTierBarTests {
    /// How many samples the gated tier runs.
    private static let subsetSampleCount = compactionEvalRepresentativeSeeds.count

    /// The two floors the gated assertions apply — the summary side and the
    /// answer side — so every property below is held for each floor a tier
    /// really uses.
    private static let checkedFloors = [
        compactionEvalSummaryFactRetentionFloor,
        compactionEvalAnswerFactRetentionFloor,
    ]

    /// The tier sizes the required-count property below is held over: every size
    /// from a single sample up to the whole dataset, so the property covers the
    /// tier this eval really runs and every size a smaller one could take.
    private static let checkedSampleCounts = 1...compactionEvalSeeds.count

    /// The bound this tier's own measured samples derive, in minutes.
    ///
    /// Derived once, so the two properties below hold the SAME arithmetic from
    /// its two sides. Its two inputs are stated apart — the tier's seed count,
    /// and the rate the tier's own dearest sample measured — because a bound
    /// another tier's rate derives is not this tier's bound (task ^5q0vv85).
    private static let derivedBoundMinutes = compactionEvalDerivedTimeLimitMinutes(
        forSamples: subsetSampleCount,
        chargedAt: compactionEvalSubsetMeasuredDearestSampleSeconds)

    /// How many of the tier's samples each floor really asks for.
    ///
    /// Both floors state 0.71 and the tier holds seven seeds, so both sides ask
    /// the same count; each floor's own doc comment derives it from the measured
    /// baseline of the ^m03heaa re-baseline of 2026-08-20, where the Qwen2.5-3B
    /// canary measured 6 of 7 on both sides. Written here as a value the test
    /// compares against, so a floor that stopped asking this count fails rather
    /// than agreeing with itself.
    private static let samplesEachFloorNeeds = 5

    @Test("the tier's time limit clears the bound its own measured samples derive")
    func tierTimeLimitClearsItsDerivedBound() {
        #expect(
            Double(compactionEvalSubsetTimeLimitMinutes) >= Self.derivedBoundMinutes,
            """
            a tier of \(Self.subsetSampleCount) seeds at \
            \(compactionEvalSubsetMeasuredDearestSampleSeconds) s for each sample derives \
            \(Self.derivedBoundMinutes) minutes, against a limit of \
            \(compactionEvalSubsetTimeLimitMinutes)
            """
        )
    }

    @Test("the tier's time limit is the next whole minute above that bound, so it states a measurement")
    func tierTimeLimitIsTheNextWholeMinuteAboveItsBound() {
        // The other half of the same property. A limit far above the derivation
        // passes the test above and states nothing, which is the defect ^6ssbakk
        // records against the 30 minutes this value replaced: a number nobody
        // can read a measurement out of. One minute is the smallest limit Swift
        // Testing accepts, so a derivation under one minute states a limit of
        // one.
        #expect(
            Double(compactionEvalSubsetTimeLimitMinutes) < max(Self.derivedBoundMinutes, 1) + 1,
            """
            a tier of \(Self.subsetSampleCount) seeds at \
            \(compactionEvalSubsetMeasuredDearestSampleSeconds) s for each sample derives \
            \(Self.derivedBoundMinutes) minutes and states \
            \(compactionEvalSubsetTimeLimitMinutes), which is more than the next whole minute \
            above it
            """
        )
    }

    @Test("each floor needs 5 of the tier's seeds")
    func eachFloorIsTheSampleCountItReallyNeeds() {
        // The metric scores one bit per sample, so a tier of n samples can only
        // produce the means k/n. Each floor's own doc comment derives this count
        // from the measured baseline — the ^m03heaa re-baseline of 2026-08-20,
        // where the Qwen2.5-3B canary measured 6 of 7 on both sides; this holds
        // the derivation.
        #expect(
            compactionEvalFactRetentionRequiredSamples(
                of: Self.subsetSampleCount, floor: compactionEvalSummaryFactRetentionFloor)
                == Self.samplesEachFloorNeeds,
            "the tier holds \(Self.subsetSampleCount) seeds against the summary floor")
        #expect(
            compactionEvalFactRetentionRequiredSamples(
                of: Self.subsetSampleCount, floor: compactionEvalAnswerFactRetentionFloor)
                == Self.samplesEachFloorNeeds,
            "the tier holds \(Self.subsetSampleCount) seeds against the answer floor")
    }

    @Test("the required count is the smallest count that clears the floor, at every tier size")
    func requiredCountIsTheSmallestCountThatClearsTheFloor() {
        for floor in Self.checkedFloors {
            for sampleCount in Self.checkedSampleCounts {
                let required = compactionEvalFactRetentionRequiredSamples(of: sampleCount, floor: floor)
                #expect(
                    Double(required) / Double(sampleCount) >= floor,
                    "a tier of \(sampleCount) samples needs \(required), which does not clear \(floor)")
                #expect(
                    Double(required - 1) / Double(sampleCount) < floor,
                    "a tier of \(sampleCount) samples needs \(required), but \(required - 1) already clears \(floor)"
                )
            }
        }
    }

    @Test("a tier of no samples needs no sample, so the arithmetic never divides by zero")
    func tierOfNoSamplesNeedsNoSample() {
        for floor in Self.checkedFloors {
            #expect(compactionEvalFactRetentionRequiredSamples(of: 0, floor: floor) == 0)
        }
    }
}

