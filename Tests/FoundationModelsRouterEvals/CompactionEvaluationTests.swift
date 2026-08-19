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

/// The dearest of the samples the gated subset run of 2026-08-18 timed apart,
/// in seconds.
///
/// One sample's own work — its fold and its answering turn together — read off
/// that sample's own progress lines. Never a run's wall clock divided by a
/// sample count: `^9cw5g6n` forbids that division, and this trail makes it
/// unnecessary, because the run drove its samples one at a time and printed each
/// sample's four lines complete before the next sample's first line.
///
/// The six samples that finished cost 197.4, 250.7, 260.9, 269.9, 295.1 and
/// 352.0 seconds. They add to 1626.0 seconds of an 1800-second run, they average
/// 271.0 seconds, and the dearest is 1.78 times the cheapest.
///
/// The DEAREST sizes a limit, not the mean, because that spread is what a limit
/// has to survive. Seven samples at the mean is 31.7 minutes and seven at this
/// rate is 41.1 minutes, and a tier that has to end on its own assertion cannot
/// be sized at the lower of the two (task ^6ssbakk).
private let compactionEvalMeasuredDearestSampleSeconds = 352.0

/// What the same run's model load cost, in seconds.
///
/// ``CompactionEvalRealModelContainer/load(samplingMode:unexpectedContainerType:)``
/// times the load on its own two progress lines, so it is charged to no sample
/// and has to be added back when a whole tier is sized. It is small and it is
/// stable: the run of 2026-08-18 08:05 measured 3.6 seconds (task ^h2xxsse) and
/// the run of 2026-08-18 16:38 measured 3.5 (task ^6ssbakk).
private let compactionEvalMeasuredModelLoadSeconds = 3.5

/// How many seconds a minute holds.
///
/// The eval's progress lines measure in seconds and Swift Testing's
/// `.timeLimit(.minutes(_:))` takes whole minutes, so every derivation below
/// crosses this rate once.
private let compactionEvalSecondsPerMinute = 60.0

/// The wall clock a gated tier of `sampleCount` samples is bounded by, in
/// minutes, derived from the samples the gated run of 2026-08-18 timed apart.
///
/// Every sample is charged ``compactionEvalMeasuredDearestSampleSeconds``, and
/// the tier is charged one ``compactionEvalMeasuredModelLoadSeconds`` on top.
/// That is a BOUND rather than an expected cost: it is what a tier takes when
/// every one of its samples lands at the dearest cost anything has measured.
///
/// The sum is the right arithmetic, and not the largest sample and not the mean.
/// The samples do not generate together whatever shape a run takes, because MLX
/// gives the one resident container serial access — see
/// ``compactionEvalSubsetTimeLimitMinutes``. So a tier of `sampleCount` samples
/// costs about `sampleCount` times one sample rather than less.
///
/// - Parameter sampleCount: How many samples the tier runs.
/// - Returns: The derived bound, in minutes.
private func compactionEvalDerivedTimeLimitMinutes(forSamples sampleCount: Int) -> Double {
    (Double(sampleCount) * compactionEvalMeasuredDearestSampleSeconds
        + compactionEvalMeasuredModelLoadSeconds) / compactionEvalSecondsPerMinute
}

/// The wall-clock ceiling the DEFAULT gated tier's `@Test` runs under, in
/// minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:)`` at the seven seeds of
/// ``compactionEvalRepresentativeSubsetIDs``: 7 x 352.0 s plus 3.5 s is 2467.5
/// seconds, which is 41.1 minutes. `CompactionEvalTierBarTests` holds this value
/// against that derivation from both sides, so a subset that outgrew its limit,
/// or a limit that stopped stating a measurement, fails a plain `swift test`
/// rather than a gated run.
///
/// ## The margin, and what can spend it
///
/// 0.9 minutes over the derived bound, and 9.0 minutes over what the run of
/// 2026-08-18 really measured — its six finished samples cost 1626.0 seconds,
/// and charging the seventh, which nothing has ever timed, at the dearest
/// measured sample gives 1981.5 seconds with the load, or 33.0 minutes.
///
/// One thing can still spend the margin: a machine that has never fetched the
/// model pays that download inside this limit. Sampling cannot, any more —
/// ``CompactionEvalRealSubjectRunner`` now pins
/// ``FoundationModels/GenerationOptions/SamplingMode/greedy``, so two runs of
/// identical code generate the same answers at the same lengths (task ^xscp198).
/// A run that ends on the limit names the seeds it never reached — see
/// ``CompactionEvalFactRetentionReport/lines(of:expecting:)`` — so an overrun
/// reads as an overrun rather than as a smaller clean sheet.
///
/// ## Why the rate rose, and why 1644.7 seconds is stale
///
/// Each sample pays for two real generations — one summarizer call inside the
/// fold, and one answering turn on the resumed session — and each is bounded in
/// thousands of output tokens rather than hundreds, because the gated model
/// always writes a `<think>` block first. See
/// ``GatedRealModelBudget/responseTokenCeiling`` and
/// ``Summarization/reasoningTokenHeadroom``.
///
/// What changed is the second generation. Until `^azd033m` every fold was
/// DISCARDED: the summarizer ran, `Compactor.compact`'s did-not-shrink guard
/// threw the result away, and the answering turn then read the original
/// transcript. The gated run of 2026-08-17 measured 7 of 7 seeds in 1644.7
/// seconds that way (task ^fz49qds). Once the fold applies, the answering turn
/// reads a folded transcript instead, and the per-sample cost rose with it.
///
/// The run of 2026-08-18 is the first where every measured fold applied — 6 of 6
/// report `folded=true` with the full stage list — and it measured six samples in
/// 1800 seconds and left the seventh in its fold. So 1644.7 seconds is stale
/// because the work changed, not because the machine did, and the 30 minutes
/// this value used to state was measured against a rate that no longer exists.
///
/// ## Read one sample's cost off the trail, and never divide a run's wall clock
///
/// The division charges each sample a share of the model load and of every gap
/// between samples, and it hides the real spread: the six samples above differ
/// by a factor of 1.78 between the cheapest and the dearest.
///
/// How many samples `Evaluations` drives at once is NOT stated anywhere, and
/// this tier cannot state it: `Evaluation.run(info:)` and the
/// `.evaluates(_:info:recordTranscripts:)` trait each take an evaluation and its
/// info, and neither takes a concurrency limit. What the framework really does
/// is not stable from run to run, and two trails of the same tier show both
/// shapes. The instrumented run of 2026-08-18 08:05 (task ^h2xxsse) printed six
/// `fold started` lines one after another with no `fold returned` line between
/// them, so six samples were in flight together. The gated run of 2026-08-18
/// 16:38 (task ^6ssbakk) ran the same dispatch code and printed each sample's
/// four lines complete before the next sample's first line, so those samples ran
/// one at a time.
///
/// Whichever shape a run takes, the samples do NOT generate together. Every
/// sample generates through the one resident container
/// ``CompactionEvalRealSubjectRunner`` caches, and MLX gives that container
/// serial access: `ModelContainer.perform` runs its whole call under a
/// `SerialAccessContainer` mutex, so one generation at a time runs on the model
/// however many samples wait. ``RoutedModel/generationGate`` is not what does
/// this here — the eval drives the bare-session recipe and builds no
/// ``RoutedSession``.
///
/// What a run past the limit reports depends on the shape that run took.
/// ^6ssbakk finished six samples one at a time and named the seventh unreached;
/// ^h2xxsse held six in flight together, finished none of them, and reported
/// `0 of 7`, which reads like a total regression and was not one.
///
/// The 20 minutes ``gatedEvalSuiteTimeLimitMinutes`` states, which this suite ran
/// under before, is below every one of these measurements. That is the limit the
/// gated run of 2026-08-17 exceeded, nine seeds into the whole dataset (task
/// ^fz49qds).
let compactionEvalSubsetTimeLimitMinutes = 42

/// The wall-clock ceiling the opt-in whole-dataset tier's `@Test` runs under,
/// in minutes.
///
/// DERIVED, not measured. Timing this tier costs the hour and a half the
/// constant exists to bound, so the value is computed from the subset tier's
/// measured samples instead, and this comment says so rather than letting a
/// reader take it for a measured one.
///
/// The arithmetic takes a sample's cost from a trail that timed each sample,
/// and never from a run's wall clock divided by a sample count. The gated run
/// of 2026-08-18 16:38 (task ^6ssbakk) timed six samples, and they cost 271.0
/// seconds each on average. Twenty-four samples at that rate is 6504 seconds —
/// 108.4 minutes.
///
/// Three facts hold that derivation up. That run drove its samples one at a
/// time — see ``compactionEvalSubsetTimeLimitMinutes`` — so each figure is one
/// sample's own work and carries no wait on another sample. The rate carries no
/// share of the model load either, because the runner times the load apart from
/// every sample and that run measured it at 3.5 seconds. And the samples
/// generate one at a time whatever shape a run takes, because MLX gives the
/// resident container serial access, so twenty-four samples cost about
/// twenty-four times one sample rather than less.
///
/// 120 leaves 11.6 minutes over the derived 108.4. That is far less room than
/// this value appeared to have while a divided rate made the derived figure 94
/// minutes. The first run of this tier should record its real duration here in
/// place of the derivation.
///
/// This value rests on the MEAN of those six samples, where
/// ``compactionEvalSubsetTimeLimitMinutes`` rests on the DEAREST of them, and
/// the two bases do not agree: twenty-four samples at the dearest rate is 140.8
/// minutes, over this limit. `CompactionEvalTierBarTests` therefore holds the
/// subset tier to its derivation and does not hold this one, which stays as
/// ^6ssbakk left it until its own card re-derives it.
let compactionEvalFullDatasetTimeLimitMinutes = 120

// MARK: - Measured tier bars

/// The mean `FactRetention` a gated tier's samples must reach.
///
/// compaction_plan.md §5's own bar, and the same value both tiers are held to —
/// the tiers differ in which seeds they measure, never in how well those seeds
/// have to do.
///
/// ## What a seed count makes of it
///
/// `FactRetention` scores one bit per sample, so a tier of `n` samples can only
/// produce the means `k/n`. This floor is therefore not the bar a tier of any
/// size really applies. The bar is the smallest `k` whose `k/n` clears it, and
/// `k/n` is usually ABOVE 0.9 rather than equal to it:
///
/// | tier | seeds | must retain | which is a mean of | may lose |
/// |---|---|---|---|---|
/// | the representative subset | 7 | 7 | 1.000 | 0 |
/// | the whole dataset | 24 | 22 | 0.917 | 2 |
///
/// So the stated bar of "at least 0.9" is, on the subset, "every seed, every
/// run": 6 of 7 is 0.857, under the floor.
/// ``compactionEvalFactRetentionRequiredSamples(of:)`` computes that,
/// `CompactionEvalTierBarTests` holds it, and ``expectFactRetention(of:)``
/// states it in the message of a failing run — so a subset whose size cannot
/// express the bar can no longer be chosen silently (task ^xscp198).
///
/// A bar with no tolerance is only worth having against a measurement that does
/// not move on its own. That is why ``CompactionEvalRealSubjectRunner`` pins
/// ``FoundationModels/GenerationOptions/SamplingMode/greedy``: two runs of
/// 2026-08-17 drove identical fold code to 7 of 7 and to 6 of 7, and the seed
/// that moved answered with its key phrase once and refused once.
///
/// ## Two bars, one number
///
/// ``expectFactRetention(of:)`` applies this floor twice — once to the share of
/// samples whose FOLD wrote a summary carrying the key phrase, and once to the
/// share whose ANSWER carried it. One number for both, because the first is a
/// necessary condition for the second: an answer can only carry a fact its own
/// transcript holds, so a tier that missed the summary bar can never make the
/// answer bar.
///
/// One number is not one measurement. The gated run of 2026-08-18 measured 4 of
/// 6 summaries carrying the fact and 2 of 6 answers carrying it, and reported
/// the second alone. The two failures behind that gap belong to different steps
/// and to different tasks: `summaryLostFact` is the fold's, and
/// `answerMissedFactSummaryCarriedIt` is the resumed session's (task ^e814b60).
private let compactionEvalFactRetentionFloor = 0.9

/// The smallest number of a tier's samples that must retain the fact for the
/// tier's mean to clear ``compactionEvalFactRetentionFloor``.
///
/// Found by the same `>=` comparison ``expectFactRetention(of:)`` applies, over
/// the counts a tier can really produce, so this arithmetic and that assertion
/// can never disagree. Computing `ceil(floor * n)` instead would disagree: the
/// nearest `Double` to 0.9 is a shade above 0.9, so `ceil(0.9 * 10)` is 10 where
/// 9 of 10 already clears the bar.
///
/// - Parameter sampleCount: How many samples the tier runs.
/// - Returns: The smallest count that clears the floor. `0` for a tier of no
///   samples, which has no count to reach; `sampleCount` for a floor above 1.0,
///   which no count clears.
private func compactionEvalFactRetentionRequiredSamples(of sampleCount: Int) -> Int {
    guard sampleCount > 0 else { return 0 }
    return (0...sampleCount).first {
        CompactionEvalFactRetentionReport.share(of: $0, over: sampleCount) >= compactionEvalFactRetentionFloor
    } ?? sampleCount
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
/// An answer that fills that allowance is the largest a WELL-BEHAVED summarizer
/// writes. That qualifier carries the whole weight, because nothing states the
/// allowance to the model. The prompt ``Summarization`` assembles names no
/// length at all, and the gated run of 2026-08-17 (task ^fm5ddk9) measured what
/// a real model does with that freedom: it called every one of 7 seeds at a
/// ceiling of 4224 tokens against an allowance of 128, and every one answered
/// with 374 to 698 real tokens — 2.9x to 5.5x the allowance. So this summarizer
/// stands for the good case. The two bounds ``Summarization`` applies in code
/// are what hold the bad one, and `Compactor.compact`'s did-not-shrink guard
/// still catches what gets past both.
///
/// Those two bounds are different numbers, and they do different jobs. This
/// summarizer reads only the first.
///
/// - ``Summarization/summaryTokenRatio`` sizes the summary allowance. The stage
///   adds ``Summarization/reasoningTokenHeadroom`` to it and hands the sum down
///   as `maxTokens`. That is a ceiling on the GENERATION, in real tokens, and it
///   covers the reasoning and the answer together.
/// - ``Summarization/summaryRetentionRatio`` sizes the cut `Summarization.cut`
///   applies to the answer the call came back with. That is a ceiling on the
///   TEXT, in the UTF-8 content bytes `Compactor` measures. It holds for every
///   answer but one: a cut that would leave no text at all hands the answer back
///   whole rather than erase the span, and the did-not-shrink guard judges it.
///
/// This summarizer answers a little over the allowance converted at
/// `Compactor.charsPerTokenEstimate` on purpose. 128 tokens at that flat rate of
/// 4.0 bytes is 512 bytes. This answers the allowance in REAL tokens at
/// ``compactionEvalMeasuredBytesPerToken`` instead — 616 bytes. So a seed
/// that clears this gate clears a summary 20% larger than the flat estimate
/// predicts.
///
/// The cut does not bind on that answer for any seed, so this gate measures a
/// seed against the summary as written and never against one the stage had
/// already trimmed. A 616-byte answer is cut only when the call's own content
/// estimates 191 tokens or fewer, and
/// `CompactionEvalSeedSizingTests/everySeedsFoldableSpanOutweighsARealSummary`
/// already requires every seed's span to estimate 231 tokens or more.
private struct RealisticSummaryLengthSummarizer: CompactionSummarizer {
    /// The headroom the stage under test adds on top of the summary allowance.
    ///
    /// Read from the same ``Summarization`` value the fold is given rather than
    /// restated, so this summarizer cannot drift away from the stage calling it.
    let reasoningTokenHeadroom: Int

    /// One sentence in the register a compaction summary is written in, repeated
    /// to reach a required size. ASCII throughout, so one character is one byte
    /// and the size ``summarize(_:maxTokens:)`` computes below is the size it
    /// produces. Nobody asks the model for that size — see the type's own
    /// documentation.
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
        // buys — see `RealisticSummaryLengthSummarizer` for what a real model
        // writes instead, since nothing states that allowance to it, which is
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

    /// One of the two probe seeds, as a share.
    ///
    /// The value `CompactionEvalFactRetentionReport/share(of:over:)` must answer
    /// for one sample in two, and the case that separates a real division from a
    /// guard answering zero whatever it is given.
    private static let halfShare = 0.5

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

    @Test("the table states what the folds carried beside what the answers carried")
    func tableStatesTheFoldShareBesideTheAnswerShare() {
        // The two are different measurements, and the tier used to report the
        // second alone. The gated run of 2026-08-18 measured 4 of 6 summaries
        // carrying the fact against 2 of 6 answers, and one mean hid that
        // (task ^xscp198).
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [
                Self.makeDiagnostic(summary: "CRIMSON-77", answer: "It is CRIMSON-77."),
                Self.makeDiagnostic(
                    summary: "PORT-6543", answer: "Noted.", question: Self.unreachedSeed.question),
            ],
            seeds: Self.bothSeeds
        )
        #expect(CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings) == findings.count)
        let table = CompactionEvalFactRetentionReport.lines(of: findings, expecting: Self.bothSeeds)
            .joined(separator: "\n")
        #expect(table.contains("retention: summary=2 of 2 answer=1 of 2"))
    }

    @Test("a fold that produced no summary counts against the fold share, because it carries nothing")
    func foldThatProducedNoSummaryCountsAgainstTheFoldShare() {
        let findings = CompactionEvalFactRetentionReport.findings(
            for: [Self.makeDiagnostic(summary: nil, answer: "I do not have that information.")],
            seeds: [Self.seed]
        )
        #expect(CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings) == 0)
        let table = CompactionEvalFactRetentionReport.lines(of: findings, expecting: [Self.seed])
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
            .fold, sample: Self.label, elapsedSeconds: nil)

        #expect(line.contains("sample=\(Self.sampleOrdinal)/\(Self.tierSeedCount)"))
        #expect(line.contains("seed=\(Self.sampleSeedID)"))
    }

    @Test("a sample's first step states no elapsed clause, rather than a zero that reads as a measurement")
    func firstStepOfASampleStatesNoElapsedClause() {
        let first = CompactionEvalProgressLog.makeStepStartedLine(
            .fold, sample: Self.label, elapsedSeconds: nil)
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

    /// The largest summary a WELL-BEHAVED summarizer writes for a span this
    /// size — one that keeps to the allowance its own call earned — in the
    /// estimated tokens ``Compactor`` measures a transcript in.
    ///
    /// "Well-behaved" is the whole qualifier, and it is measured. Nothing states
    /// the allowance to the model: the prompt `Summarization` assembles names no
    /// length at all. So the gated run of 2026-08-17 measured summaries of 450 to
    /// 840 estimated tokens against this bound of 154 — task ^fm5ddk9.
    ///
    /// The bound below is therefore what a summarizer WRITES, and not what the
    /// fold asks for, because the fold asks for nothing. `Summarization` bounds a
    /// call in code instead, twice over, and neither bound is this number.
    /// ``Summarization/summaryTokenRatio`` sizes the output-token ceiling the
    /// call generates under, which covers the reasoning and the answer together
    /// and so bounds neither one alone. ``Summarization/summaryRetentionRatio``
    /// sizes the cut applied to the answer itself, in UTF-8 content bytes, and
    /// that one really does bound a stored summary — except for the answer whose
    /// cut would leave no text, which `Summarization` hands back whole rather
    /// than erase the span.
    ///
    /// The cut does not bind on any seed, so it never lowers this bound here. It
    /// binds only on a call whose content estimates 191 tokens or fewer, and
    /// ``summaryShrinkClearance`` holds every seed's span at 231 or more. A
    /// summary past this bound therefore reaches `Compactor.compact`'s
    /// did-not-shrink guard whole, and that guard is what discards the fold.
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
        // against a 128-token floor that is 616 bytes at
        // `compactionEvalMeasuredBytesPerToken`. The fold cost more than it
        // saved, and `Compactor.compact` was right to throw it away.
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
    /// anything, and the upper bound is the seed count
    /// ``compactionEvalSubsetTimeLimitMinutes`` was derived for — a subset that
    /// grew past it would no longer fit that limit. The band used to reach 8,
    /// which stopped being true when the applied fold raised the per-sample rate:
    /// 8 samples at the rate `CompactionEvalTierBarTests` derives the limit from
    /// is 46.9 minutes, over the 42 the limit states (task ^6ssbakk).
    private static let subsetSizeBand = 6...7

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

// MARK: - Ungated tier thresholds

/// Ungated proof that each gated tier's two thresholds — the wall clock it runs
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
    /// How many samples the default gated tier runs.
    private static let subsetSampleCount = compactionEvalRepresentativeSeeds.count

    /// How many samples the opt-in whole-dataset tier runs.
    private static let fullDatasetSampleCount = compactionEvalSeeds.count

    /// How many of the whole dataset's seeds must retain the fact for its mean
    /// to clear ``compactionEvalFactRetentionFloor`` — 22, because 22 of 24 is
    /// 0.917 and 21 of 24 is 0.875.
    private static let fullDatasetRequiredSamples = 22

    /// The tier sizes the required-count property below is held over: every size
    /// from a single sample up to the whole dataset, so the property covers the
    /// two tiers this eval really runs and every size between them.
    private static let checkedSampleCounts = 1...compactionEvalSeeds.count

    @Test("the subset's time limit clears the bound its own measured samples derive")
    func subsetTimeLimitClearsItsDerivedBound() {
        let derived = compactionEvalDerivedTimeLimitMinutes(forSamples: Self.subsetSampleCount)
        #expect(
            Double(compactionEvalSubsetTimeLimitMinutes) >= derived,
            """
            the subset tier holds \(Self.subsetSampleCount) seeds, which derive \(derived) minutes, \
            against a limit of \(compactionEvalSubsetTimeLimitMinutes)
            """
        )
    }

    @Test("the subset's time limit is the next whole minute above that bound, so it states a measurement")
    func subsetTimeLimitIsTheNextWholeMinuteAboveItsBound() {
        // The other half of the same property. A limit far above the derivation
        // passes the test above and states nothing, which is the defect ^6ssbakk
        // records against the 30 minutes this value replaced: a number nobody
        // can read a measurement out of.
        let derived = compactionEvalDerivedTimeLimitMinutes(forSamples: Self.subsetSampleCount)
        #expect(
            Double(compactionEvalSubsetTimeLimitMinutes) < derived + 1,
            """
            the subset tier derives \(derived) minutes and states \(compactionEvalSubsetTimeLimitMinutes), \
            which is more than the next whole minute above it
            """
        )
    }

    @Test("the floor needs every seed of the subset, and 22 of the whole dataset")
    func eachTiersFloorIsTheSampleCountItReallyNeeds() {
        // `FactRetention` scores one bit per sample, so a tier of n samples can
        // only produce the means k/n. A 7-seed tier held to 0.9 passes at 7 of 7
        // and at no other count, because 6 of 7 is 0.857.
        #expect(
            compactionEvalFactRetentionRequiredSamples(of: Self.subsetSampleCount) == Self.subsetSampleCount,
            "the subset holds \(Self.subsetSampleCount) seeds and can lose none of them")
        #expect(
            compactionEvalFactRetentionRequiredSamples(of: Self.fullDatasetSampleCount)
                == Self.fullDatasetRequiredSamples,
            "the whole dataset holds \(Self.fullDatasetSampleCount) seeds")
    }

    @Test("the required count is the smallest count that clears the floor, at every tier size")
    func requiredCountIsTheSmallestCountThatClearsTheFloor() {
        for sampleCount in Self.checkedSampleCounts {
            let required = compactionEvalFactRetentionRequiredSamples(of: sampleCount)
            #expect(
                Double(required) / Double(sampleCount) >= compactionEvalFactRetentionFloor,
                "a tier of \(sampleCount) samples needs \(required), which does not clear the floor")
            #expect(
                Double(required - 1) / Double(sampleCount) < compactionEvalFactRetentionFloor,
                "a tier of \(sampleCount) samples needs \(required), but \(required - 1) already clears the floor")
        }
    }

    @Test("a tier of no samples needs no sample, so the arithmetic never divides by zero")
    func tierOfNoSamplesNeedsNoSample() {
        #expect(compactionEvalFactRetentionRequiredSamples(of: 0) == 0)
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

/// Prints one tier's per-sample evidence, then asserts the two bars its samples
/// are held to.
///
/// Shared by both tiers so the two can never drift into measuring the same
/// metric two ways.
///
/// Two assertions rather than one, because the tier spans two steps. The FOLD
/// has to write a summary carrying the planted fact, and the resumed session has
/// then to ANSWER with it. Both are held to
/// ``compactionEvalFactRetentionFloor`` — see that value for why one number
/// serves both — and each states, in its own message, how many samples cleared
/// it and how many the seed count really needs.
///
/// - Parameter runner: The tier's runner, holding the evidence its samples
///   recorded and the seed set that evidence is read against — so a run the
///   time limit cut short states the seeds it never reached.
private func expectFactRetention(of runner: CompactionEvalRealSubjectRunner) async {
    // Printed before the assertions so a run that misses a bar still
    // leaves the evidence behind: a mean alone cannot say whether a
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

    let measured = findings.count
    let required = compactionEvalFactRetentionRequiredSamples(of: seeds.count)
    let bar = "a floor of \(compactionEvalFactRetentionFloor) over \(seeds.count) seeds needs \(required) of them"

    // The COMPACTION side, asserted first because it is the necessary
    // condition: a tier whose folds dropped the fact can never answer with it.
    let summaryCarried = CompactionEvalFactRetentionReport.summaryFactRetentionCount(of: findings)
    #expect(
        CompactionEvalFactRetentionReport.share(of: summaryCarried, over: measured)
            >= compactionEvalFactRetentionFloor,
        "\(summaryCarried) of \(measured) folds wrote a summary carrying the fact, and \(bar)"
    )

    // The end-to-end bar, read off the framework's own metric rather than off
    // the table, so this assertion and `FactRetention` can never disagree.
    let result = EvaluationContext.current.result
    let answerCarried = CompactionEvalFactRetentionReport.counts(of: findings)[.retained] ?? 0
    #expect(
        result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= compactionEvalFactRetentionFloor,
        "\(answerCarried) of \(measured) answers carried the fact, and \(bar)"
    )
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
