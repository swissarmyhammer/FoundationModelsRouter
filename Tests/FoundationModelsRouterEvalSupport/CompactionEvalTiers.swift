import FoundationModels
import FoundationModelsRouter

// MARK: - Measured tier limits

/// The dearest of the samples the gated subset run of 2026-08-20 timed apart,
/// in seconds.
///
/// One sample's own work — its fold and its answering turn together — read off
/// that sample's own progress lines. Never a run's wall clock divided by a
/// sample count: `^9cw5g6n` forbids that division, and this trail makes it
/// unnecessary, because the run drove its samples one at a time and printed
/// each sample's four lines complete before the next sample's first line.
///
/// Measured against ``CompactionEvalRealModel`` — Qwen2.5-3B-Instruct since
/// task ^m03heaa put it in place of the 1B canary — with every summarizer call
/// bounded by ``compactionEvalReasoningTokenHeadroom``, under task ^xx02yn6's
/// span-budget trim and its `router-default-v3` prompt, at greedy decoding.
/// The seven samples cost 5.4, 4.7, 12.1, 3.2, 5.1, 15.9 and 15.9 seconds.
/// Four of the seven folds made one summarizer call and three made two,
/// because the redesigned stage re-asks: an answer past the span byte budget
/// earns one condense call before the last-resort cut. The rate rose from the
/// 7.2-second dearest sample the 1B canary measured over the same recipe on
/// the same day, which is what a model of three times the parameters costs to
/// decode. The 30B run of 2026-08-18 measured 197.4 to 352.0 seconds per
/// sample over the same recipe, which is the rate the two-minute budget
/// removed.
///
/// Every one of those seven samples APPLIED its fold, and that is half of the
/// cost each figure holds: the answering turn then reads the folded
/// transcript. Task ^azd033m made the fold apply. Before that change a fold
/// was discarded, and a discarded fold costs one summarizer call and nothing
/// after it, so a rate measured over discarded folds under-states this one —
/// which is why the 7-sample run of 2026-08-17 is not comparable with any
/// figure above. The run of 2026-08-20 filed six of its seven samples as
/// `retained` and one as `summaryLostFact`, and none as
/// ``CompactionEvalFactRetentionClass/foldProducedNoSummary``, which is how
/// its own trail shows that each fold applied. Two ungated tests keep the
/// property true without a gated run:
/// `CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary`
/// folds every seed against a summarizer that answers at a real summary's
/// length, and
/// `CompactionEvalSeedSizingTests/everySeedsFoldableSpanOutweighsARealSummary`
/// holds every seed's foldable span above the largest summary such a
/// summarizer writes for it. So `Compactor.compact` cannot throw a fold away
/// on its did-not-shrink guard (task ^6ssbakk).
///
/// The DEAREST sizes a limit, not the mean, because the spread between
/// samples is what a limit has to survive (task ^6ssbakk).
///
/// This rate sizes the SUBSET tier and no other. The whole-dataset tier was
/// sized from it as well until task ^5q0vv85, and the two runs of 2026-08-20
/// show why that was wrong. `three-facts-support-escalation` is one of the
/// seven seeds above, and it cost 15.9 seconds as sample 7 here and 82.4
/// seconds as sample 21 of the whole-dataset run; `three-facts-long-project-brief`
/// is another, and it cost 15.9 seconds as sample 6 here and 56.5 seconds as
/// sample 18 there. Each seed did the SAME work in both runs — two summarizer
/// calls, and 1948 and 2103 summary bytes, which greedy decoding repeats — so
/// what changed is throughput, and a rate measured over a short run cannot
/// bound a long one. Each tier therefore charges its own measured rate; the
/// other one is ``compactionEvalFullDatasetMeasuredDearestSampleSeconds``.
let compactionEvalSubsetMeasuredDearestSampleSeconds = 15.9

/// The dearest of the samples the gated WHOLE-DATASET run of 2026-08-20 timed
/// apart, in seconds.
///
/// Timed as ``compactionEvalSubsetMeasuredDearestSampleSeconds`` is timed: one
/// sample's own work — its fold and its answering turn together — read off that
/// sample's own progress lines, and never a run's wall clock divided by a
/// sample count, which `^9cw5g6n` forbids. The run drove its samples one at a
/// time and printed each sample's four lines complete before the next sample's
/// first line.
///
/// Measured against ``CompactionEvalRealModel`` under the same recipe as the
/// subset run of the same day: every summarizer call bounded by
/// ``compactionEvalReasoningTokenHeadroom``, task ^xx02yn6's span-budget trim
/// and its `router-default-v3` prompt, at greedy decoding. The 24 samples cost
/// 11.0, 5.4, 5.1, 3.8, 4.7, 12.2, 3.2, 4.1, 5.9, 5.1, 4.3, 3.3, 4.2, 6.6,
/// 11.0, 3.9, 3.8, 56.5, 24.3, 23.0, 82.4, 27.6, 11.5 and 44.7 seconds, in
/// dataset order. They add to 367.6 seconds, and with the 1.3-second model load
/// that no sample carries that is 368.9 against the 369.1 seconds of wall clock
/// the run reported — which is how this trail shows that it holds every sample.
///
/// The spread inside that ONE run is 3.2 to 82.4 seconds, and it follows the
/// position in the run rather than the seed: the last seven samples hold the
/// six dearest. That is the property this constant exists for. A tier's
/// per-sample rate is a fact about the tier's own length, so no other tier's
/// rate bounds these samples (task ^5q0vv85).
///
/// The DEAREST sizes a limit, not the mean, because the spread between samples
/// is what a limit has to survive (task ^6ssbakk).
let compactionEvalFullDatasetMeasuredDearestSampleSeconds = 82.4

/// What the two runs of 2026-08-20 measured the model load at, in seconds.
///
/// ``CompactionEvalRealModelContainer/load(ref:context:samplingMode:unexpectedContainerType:)``
/// times the load on its own two progress lines, so it is charged to no sample
/// and has to be added back when a whole tier is sized. The two runs of
/// 2026-08-20 measured Qwen2.5-3B's load at 1.2 seconds on the subset tier and
/// 1.3 on the whole-dataset tier, where the 1B canary it replaced loaded in
/// 1.8 to 2.0 and the 30B loaded in 3.5 to 3.6 (tasks ^h2xxsse, ^6ssbakk). The
/// larger of the two measured loads of the current subject is kept, so the
/// derived bounds never under-state.
private let compactionEvalMeasuredModelLoadSeconds = 1.3

/// How many seconds a minute holds.
///
/// The eval's progress lines measure in seconds and Swift Testing's
/// `.timeLimit(.minutes(_:))` takes whole minutes, so every derivation below
/// crosses this rate once.
private let compactionEvalSecondsPerMinute = 60.0

/// The wall clock a gated tier of `sampleCount` samples is bounded by, in
/// minutes, when every one of those samples is charged
/// `dearestSampleSeconds`.
///
/// Every sample is charged the rate the CALLER states, and the tier is charged
/// one ``compactionEvalMeasuredModelLoadSeconds`` on top. That is a BOUND
/// rather than an expected cost: it is what a tier takes when every one of its
/// samples lands at the dearest cost that tier has measured.
///
/// The rate is a parameter, and deliberately not one constant this arithmetic
/// reads for every tier. A rate measured over a short run does not bound a long
/// one: the two runs of 2026-08-20 measured two seeds that BOTH tiers hold at
/// 15.9 seconds each in the seven-sample subset run, and at 82.4 and 56.5
/// seconds in the twenty-four-sample run, for the same work at greedy decoding
/// (task ^5q0vv85). So each tier states its own measured rate —
/// ``compactionEvalSubsetMeasuredDearestSampleSeconds`` and
/// ``compactionEvalFullDatasetMeasuredDearestSampleSeconds`` — and this one
/// arithmetic charges whichever it is given.
///
/// The sum is the right arithmetic, and not the largest sample and not the mean.
/// The samples run one at a time whatever shape the framework dispatches,
/// because each gated runner holds a value-1 permit around one sample's whole
/// run (task ^23qeprz) — `Evaluation.run(info:)` itself takes no concurrency
/// limit, and the hermetic `CompactionEvalDispatchShapeTests` states what the
/// framework does today. So a tier of `sampleCount` samples costs about
/// `sampleCount` times one sample rather than less.
///
/// - Parameters:
///   - sampleCount: How many samples the tier runs.
///   - dearestSampleSeconds: What the dearest of that tier's OWN measured
///     samples cost, in seconds.
/// - Returns: The derived bound, in minutes.
func compactionEvalDerivedTimeLimitMinutes(
    forSamples sampleCount: Int,
    chargedAt dearestSampleSeconds: Double
) -> Double {
    (Double(sampleCount) * dearestSampleSeconds
        + compactionEvalMeasuredModelLoadSeconds) / compactionEvalSecondsPerMinute
}

/// The wall-clock ceiling the DEFAULT gated tier's `@Test` runs under, in
/// minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)`` at the
/// seven seeds of ``compactionEvalRepresentativeSubsetIDs``, charged at this
/// tier's OWN measured rate,
/// ``compactionEvalSubsetMeasuredDearestSampleSeconds``: 7 x 15.9 s plus 1.3 s
/// is 112.6 seconds, which is 1.88 minutes, so this states 2.
/// `CompactionEvalTierBarTests` holds this value against
/// that derivation from both sides, so a subset that outgrew its limit, or a
/// limit that stopped stating a measurement, fails a plain `swift test`
/// rather than a gated run.
///
/// The measured run behind the derivation is the gated subset run of
/// 2026-08-20 against ``CompactionEvalRealModel``, under task ^xx02yn6's
/// span-budget trim, whose whole wall clock was 63.5 seconds — the seconds
/// the derivation does not carry are the framework's own dispatch and
/// report, spent outside any sample's own trail. That measured 63.5 seconds
/// is inside task ^k0d30s4's two-minute budget for every integration test,
/// which is the property task ^m03heaa had to keep while it changed the
/// canary, and the limit of 2 minutes states the same budget. The 1 minute
/// this value stated before ^m03heaa was derived from the 1B canary's
/// 7.2-second dearest sample, and the 42 minutes it stated before ^6ssbakk
/// from the 30B model's 197.4-to-352.0-second samples.
///
/// One thing can still spend the margin: a machine that has never fetched the
/// model pays that download inside this limit. Sampling cannot —
/// ``CompactionEvalRealSubjectRunner`` pins
/// ``FoundationModels/GenerationOptions/SamplingMode/greedy``, so two runs of
/// identical code generate the same answers at the same lengths (task
/// ^xscp198). A run that ends on the limit names the seeds it never reached —
/// see ``CompactionEvalFactRetentionReport/lines(of:expecting:)`` — so an
/// overrun reads as an overrun rather than as a smaller clean sheet.
let compactionEvalSubsetTimeLimitMinutes = 2

/// The wall-clock ceiling the opt-in whole-dataset tier's `@Test` runs under,
/// in minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)`` at the
/// whole dataset's 24 seeds, charged at this tier's OWN measured rate,
/// ``compactionEvalFullDatasetMeasuredDearestSampleSeconds``: 24 x 82.4 s plus
/// 1.3 s is 1978.9 seconds, which is 32.98 minutes, so this states 33. The
/// samples run one at a time whatever shape the framework dispatches, because
/// the runner holds a value-1 permit around one sample's whole run (task
/// ^23qeprz), so twenty-four samples cost about twenty-four times one sample
/// rather than less.
///
/// The tier itself is measured, not only derived: the gated whole-dataset
/// run of 2026-08-20 against ``CompactionEvalRealModel``, under task
/// ^xx02yn6's span-budget trim, measured a wall clock of 369.1 seconds over
/// all 24 seeds with none unreached. The bound is 5.4 times that, and the
/// distance is the point rather than a defect: the bound charges EVERY sample
/// at the dearest, and this tier's samples spread from 3.2 to 82.4 seconds
/// inside that one run. A tier must never REACH its limit, because a run that
/// reaches one takes a Metal abort in place of a failure (fork card ^3axg80k),
/// so the limit has to cover the run in which every sample lands where the
/// dearest landed. This tier is the opt-in one, outside task ^k0d30s4's
/// two-minute budget for the everyday command, which skips it.
///
/// The 7 minutes this stated before task ^5q0vv85 came from the SUBSET tier's
/// rate of 15.9 seconds: 24 x 15.9 s plus 1.3 s is 382.9 seconds. The measured
/// 369.1 sat inside that by 13.8 seconds, which is 3.6 percent, and the margin
/// was luck rather than a bound: this tier's own late samples cost up to 82.4
/// seconds, far above the subset's dearest, and the two errors cancelled,
/// because most samples here are cheaper than the subset's dearest while a few
/// are five times dearer. A bound another tier's rate derives is not this
/// tier's bound.
///
/// The 3 minutes this value stated before ^m03heaa was derived from the 1B
/// canary's 7.2-second dearest sample, and the 120 minutes it stated before
/// ^6ssbakk from the 30B model's 271.0-second mean sample.
/// `CompactionEvalTierBarTests` holds this tier against its OWN rate from both
/// sides, as it holds the subset tier against the subset's.
let compactionEvalFullDatasetTimeLimitMinutes = 33

// MARK: - Measured tier bars

/// The mean SUMMARY fact retention a gated tier's samples must reach: the
/// share of folds whose summary carries the planted key phrase.
///
/// ## The canary's measured baseline, minus one sample of margin
///
/// The bar was 0.9 for both sides while the tiers drove the 30B model —
/// compaction_plan.md §5's own bar. Task ^k0d30s4's two-minute budget swapped
/// the subject for ``CompactionEvalRealModel``, and the bar follows the
/// subject: a bar the subject cannot reach measures the model rather than
/// the compaction prompt. The floor is the WEAKER tier's measured share
/// minus one sample of that tier's margin.
///
/// Task ^m03heaa re-measured both tiers against the canary it chose,
/// Qwen2.5-3B-Instruct, under task ^xx02yn6's span-budget trim and its
/// `router-default-v3` size-budget prompt, at greedy decoding. The gated
/// runs of 2026-08-20 measured 6 of 7 subset summaries and 23 of 24
/// whole-dataset summaries carrying the fact. One sample under each is 5 of
/// 7, which is 0.714, and 22 of 24, which is 0.917, so the WEAKER tier is
/// the subset and this floor comes from its 5 of 7. It is written as 0.71,
/// which sits under 5/7 and over 4/7, so the subset must retain exactly
/// those 5.
///
/// The 0.14 this value stated before ^m03heaa was the same rule over the 1B
/// canary that ran here until then: task ^xx02yn6's prompt redesign, built
/// for Qwen3.8-27B (the standard model, which the redesign took from 0 of 7
/// to 5 of 7 subset summaries), took the 1B the OTHER way, from 6 of 7 to 2
/// of 7 subset summaries and from 17 of 24 to 13 of 24 whole-dataset ones.
/// The 1B overshoots the stated size budget on most seeds, its answers
/// enumerate background head-first, and the last-resort cut then drops the
/// facts stated later in the span. A floor of 0.14 asked 1 of the subset's 7
/// seeds, which a change that breaks half of the retained seeds still
/// cleared. ^m03heaa answered that by changing the canary rather than the
/// rule.
///
/// ## What a seed count makes of it
///
/// The metric scores one bit per sample, so a tier of `n` samples can only
/// produce the means `k/n`. The bar a tier really applies is the smallest `k`
/// whose `k/n` clears the floor:
///
/// | tier | seeds | summaries that must carry the fact | which is a mean of |
/// |---|---|---|---|
/// | the representative subset | 7 | 5 | 0.714 |
/// | the whole dataset | 24 | 18 | 0.750 |
///
/// The whole dataset's 18 is what 0.71 asks of 24 seeds, because 17 of 24 is
/// 0.708 and misses. Its measured 23 clears that with five seeds to spare.
///
/// ``compactionEvalFactRetentionRequiredSamples(of:floor:)`` computes that,
/// `CompactionEvalTierBarTests` holds it, and ``expectFactRetention(of:)``
/// states it in the message of a failing run — so a subset whose size cannot
/// express the bar can no longer be chosen silently (task ^xscp198).
///
/// A bar with no tolerance is only worth having against a measurement that
/// does not move on its own. That is why ``CompactionEvalRealSubjectRunner``
/// pins ``FoundationModels/GenerationOptions/SamplingMode/greedy``: argmax
/// decoding consumes no randomness, so a run's score is a fact about the
/// prompt and the fixtures, and a drop under this floor is a regression in
/// the fold rather than a draw.
let compactionEvalSummaryFactRetentionFloor = 0.71

/// The mean end-to-end `FactRetention` a gated tier's samples must reach: the
/// share of ANSWERS carrying the planted key phrase after the resumed session
/// reads the folded transcript.
///
/// Never above ``compactionEvalSummaryFactRetentionFloor``, and that order
/// is structural: an answer can only carry a fact its own transcript holds,
/// so the summary share bounds this one from above. The two sides carried
/// ONE number while the 30B model ran both near 0.9; the 1B canary
/// separated them on 2026-08-19 (6 of 7 subset summaries against 5 of 7
/// subset answers, 17 of 24 whole-dataset summaries against 13 of 24
/// whole-dataset answers), so each side states its own floor: the weaker
/// tier's measured baseline minus one sample of that tier's margin.
///
/// Task ^m03heaa's re-baseline of 2026-08-20 under Qwen2.5-3B-Instruct (see
/// the summary floor above for the whole story) measured 6 of 7 subset
/// answers and 23 of 24 whole-dataset answers. One sample under each is 5 of
/// 7, which is 0.714, and 22 of 24, which is 0.917, so the weaker tier is
/// the subset and this floor comes from its 5 of 7. Written as 0.71, it asks
/// 5 of the subset's 7 seeds and 18 of the whole dataset's 24.
///
/// The two sides meet at the same number here because the 3B canary answered
/// with the fact on every seed whose summary carried it, on both tiers; the
/// constants stay separate because they state separate measurements. The
/// 0.14 this value stated before ^m03heaa was the same rule over the 1B
/// canary's 2 of 7 subset answers and 9 of 24 whole-dataset answers.
let compactionEvalAnswerFactRetentionFloor = 0.71

/// The smallest number of a tier's samples that must retain the fact for the
/// tier's mean to clear `floor`.
///
/// Found by the same `>=` comparison ``expectFactRetention(of:)`` applies to
/// its SUMMARY share, over the counts a tier can really produce, so this
/// arithmetic and that one assertion can never disagree.
///
/// The guarantee reaches that assertion and no further, because the two sides
/// read different recordings on purpose. The answer side reads the Evaluations
/// framework's own `.mean(of:)` rather than
/// ``CompactionEvalFactRetentionReport/share(of:over:)``, so the tier's
/// end-to-end verdict IS the framework's verdict rather than a second derivation
/// of it that could drift from the metric it reports. The `>=` is the same on
/// both sides; what differs is the floor each side states and which recording
/// each share is taken over (task ^xscp198).
///
/// Computing `ceil(floor * n)` instead would disagree: the nearest `Double` to
/// 0.9 is a shade above 0.9, so `ceil(0.9 * 10)` is 10 where 9 of 10 already
/// clears the bar.
///
/// - Parameters:
///   - sampleCount: How many samples the tier runs.
///   - floor: The mean the tier's samples must reach —
///     ``compactionEvalSummaryFactRetentionFloor`` or
///     ``compactionEvalAnswerFactRetentionFloor``.
/// - Returns: The smallest count that clears the floor. `0` for a tier of no
///   samples, which has no count to reach; `sampleCount` for a floor above 1.0,
///   which no count clears.
func compactionEvalFactRetentionRequiredSamples(of sampleCount: Int, floor: Double) -> Int {
    guard sampleCount > 0 else { return 0 }
    return (0...sampleCount).first {
        CompactionEvalFactRetentionReport.share(of: $0, over: sampleCount) >= floor
    } ?? sampleCount
}

// MARK: - Measured sizing

/// What one token of this dataset's own English prose costs in UTF-8 bytes,
/// under the tokenizers of the models the gated evals run
/// (``CompactionEvalRealModel/ref`` and
/// ``CompactionContinuityRealModel/ref``).
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
/// The corpus is this dataset's whole prose — every fixture's
/// ``CompactionEvalFixtureSpec/context`` and facts, every acknowledgement, and
/// every ``compactionEvalFillerTurns`` prompt and reply. That is 85 pieces of
/// text and 31541 UTF-8 bytes. Each piece is encoded on its own and the token
/// counts are summed, over each model's own `tokenizer.json` out of the local
/// Hub cache:
///
/// | tokenizer | tokens | bytes for each token |
/// |---|---|---|
/// | Muse Glimmer 30B | 6564 | 4.805 |
/// | Llama 3.2 1B | 6577 | 4.796 |
/// | Qwen2.5 3B | 6602 | 4.777 |
///
/// This value deliberately keeps the LARGEST of those rates, rounded up, so
/// the summary sizes it feeds are never under-stated. Task ^m03heaa measured
/// the Qwen2.5-3B row when that model became the fact-retention canary, and
/// re-measured the Llama row over this same corpus; the 3B is the smallest of
/// the three, so the constant did not move. The 4.524 this doc stated for the
/// Llama tokenizer before ^m03heaa was taken over a different corpus — the
/// single-line literals of the two dataset sources, 8776 bytes against 1940
/// tokens — which is why the table above re-states it.
///
/// Every use of this constant converts a real-token allowance into the bytes
/// a real summary occupies, so the largest rate over-states every such
/// summary and each gate it feeds stays strict: the hermetic shrink gate
/// folds against a summary bigger than the model writes, and the seed sizing
/// outweighs a worst case bigger than the real one.
let compactionEvalMeasuredBytesPerToken = 4.81

/// The ceiling one summarizer call of an eval-sized fold is given at the
/// PRODUCTION defaults: ``Summarization/minimumSummaryTokens`` — the FLOOR
/// of the summary allowance, which task ^xx02yn6 derives from the stated
/// size budget for larger spans — plus
/// ``Summarization/reasoningTokenHeadroom``.
///
/// Read off the stage's own values rather than restated as a literal, so a
/// recorded sample here can never claim a ceiling the stage does not hand
/// out. The hermetic report tests build their recorded calls at this number.
/// The GATED tiers run under ``compactionEvalReasoningTokenHeadroom``
/// instead, so their recorded calls carry a smaller ceiling; nothing compares
/// the two, and the report renders whichever ceiling the call really had.
let compactionEvalSummarizerCeiling =
    Summarization.minimumSummaryTokens + Summarization().reasoningTokenHeadroom

/// The tokens every GATED summarizer call is given on top of its summary
/// allowance, and deliberately not ``Summarization``'s own default of 8192.
///
/// The default is sized for a model that writes a `<think>` block before its
/// answer. Neither gated subject writes one: ``CompactionEvalRealModel/ref``
/// is a Qwen2.5 instruct model, which task ^m03heaa chose in part to keep
/// this property, and ``CompactionContinuityRealModel/ref`` a Llama 3.2
/// instruct model. So the default hands each of them thousands of tokens of
/// free generation. The gated subset run of 2026-08-19 measured what that
/// freedom costs: two of seven folds generated to the ceiling — 20485 and
/// 16060 bytes of summary answer — at 28.5 seconds each, where the five
/// bounded folds cost 2.5 to 7.4 seconds. The three fast compaction smoke
/// suites cut the same value for the same measured reason. Every gated eval
/// tier reads this one constant, so they cannot drift.
let compactionEvalReasoningTokenHeadroom = 128

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
/// writes — one that keeps to the word-count target the assembled prompt
/// states for it (task ^xx02yn6). The gated run of 2026-08-17 (task ^fm5ddk9)
/// measured what a real model did when nothing was stated: it called every one
/// of 7 seeds at a ceiling of 4224 tokens against an allowance of 128, and
/// every one answered with 374 to 698 real tokens — 2.9x to 5.5x the
/// allowance. So this summarizer stands for the good case. The generation
/// ceiling and the span byte budget ``Summarization`` applies in code are what
/// hold the bad one, and `Compactor.compact`'s did-not-shrink guard still
/// catches what gets past both.
///
/// Those two bounds are different numbers, and they do different jobs. This
/// summarizer reads only the first.
///
/// - The stated size budget sizes the summary allowance (task ^xx02yn6:
///   ``Summarization/statedBudgetShareOfContent`` of the span's content
///   bytes, capped by ``Summarization/summaryTokenRatio``, floored at
///   ``Summarization/minimumSummaryTokens``), so the ceiling always covers
///   the budget the prompt states. The stage adds
///   ``Summarization/reasoningTokenHeadroom`` to it and hands the sum down
///   as `maxTokens`. That is a ceiling on the GENERATION, in real tokens,
///   and it covers the reasoning and the answer together.
/// - The span byte budget bounds the FINAL summary the fold stores, in the
///   UTF-8 content bytes `Compactor` measures: an answer past it earns one
///   condense re-ask, then the last-resort cut — except when the cut would
///   leave no text at all, where `Summarization` hands the answer back whole
///   rather than erase the span, and the did-not-shrink guard judges it.
///
/// This summarizer answers a little over the allowance converted at
/// `Compactor.charsPerTokenEstimate` on purpose. 128 tokens at that flat rate of
/// 4.0 bytes is 512 bytes. This answers the allowance in REAL tokens at
/// ``compactionEvalMeasuredBytesPerToken`` instead — 616 bytes. So a seed
/// that clears this gate clears a summary 20% larger than the flat estimate
/// predicts.
///
/// The span byte budget does not bind on that answer for any seed, so this
/// gate measures a seed against the summary as written and never against one
/// the stage had already condensed or cut. A 616-byte answer overruns the
/// budget only when the span's content is under roughly 620 bytes, and
/// `CompactionEvalSeedSizingTests/everySeedsFoldableSpanOutweighsARealSummary`
/// already requires every seed's span to estimate 231 tokens — 924 bytes — or
/// more.
struct RealisticSummaryLengthSummarizer: CompactionSummarizer {
    /// The headroom the stage under test adds on top of the summary allowance.
    ///
    /// Read from the same ``Summarization`` value the fold is given rather than
    /// restated, so this summarizer cannot drift away from the stage calling it.
    let reasoningTokenHeadroom: Int

    /// One sentence in the register a compaction summary is written in, repeated
    /// to reach a required size. ASCII throughout, so one character is one byte
    /// and the size ``summarize(_:maxTokens:)`` computes below is the size it
    /// produces — read off the ceiling the call carries, not off the stated
    /// word-count target in the prompt; see the type's own documentation.
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

