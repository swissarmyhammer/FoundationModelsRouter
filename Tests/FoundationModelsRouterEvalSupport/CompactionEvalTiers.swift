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
/// Measured against ``CompactionEvalRealModel`` — the small model since task
/// ^k0d30s4's two-minute budget — with every summarizer call bounded by
/// ``compactionEvalReasoningTokenHeadroom``, under task ^xx02yn6's span-budget
/// trim. The seven samples cost 3.4, 1.4, 6.0, 6.0, 6.3, 6.2 and 7.2 seconds.
/// The rate rose from the 3.5-second dearest sample of 2026-08-19 because the
/// redesigned stage re-asks: an answer past the span byte budget earns one
/// condense call before the last-resort cut, and this run's small model
/// overshot its stated budget on six of the seven seeds, so those folds each
/// made two summarizer calls. The 30B run of 2026-08-18 measured 197.4 to
/// 352.0 seconds per sample over the same recipe, which is the rate the
/// two-minute budget removed.
///
/// The DEAREST sizes a limit, not the mean, because the spread between
/// samples is what a limit has to survive (task ^6ssbakk).
private let compactionEvalMeasuredDearestSampleSeconds = 7.2

/// What the same run's model load cost, in seconds.
///
/// ``CompactionEvalRealModelContainer/load(samplingMode:unexpectedContainerType:)``
/// times the load on its own two progress lines, so it is charged to no sample
/// and has to be added back when a whole tier is sized. The run of 2026-08-20
/// measured the small model's load at 1.8 seconds (2.0 on 2026-08-19), where
/// the 30B loaded in 3.5 to 3.6 (tasks ^h2xxsse, ^6ssbakk). The larger of the
/// two small-model loads is kept, so the derived bounds never under-state.
private let compactionEvalMeasuredModelLoadSeconds = 2.0

/// How many seconds a minute holds.
///
/// The eval's progress lines measure in seconds and Swift Testing's
/// `.timeLimit(.minutes(_:))` takes whole minutes, so every derivation below
/// crosses this rate once.
private let compactionEvalSecondsPerMinute = 60.0

/// The wall clock a gated tier of `sampleCount` samples is bounded by, in
/// minutes, derived from the samples the gated run of 2026-08-20 timed apart.
///
/// Every sample is charged ``compactionEvalMeasuredDearestSampleSeconds``, and
/// the tier is charged one ``compactionEvalMeasuredModelLoadSeconds`` on top.
/// That is a BOUND rather than an expected cost: it is what a tier takes when
/// every one of its samples lands at the dearest cost anything has measured.
///
/// The sum is the right arithmetic, and not the largest sample and not the mean.
/// The samples run one at a time whatever shape the framework dispatches,
/// because each gated runner holds a value-1 permit around one sample's whole
/// run (task ^23qeprz) — `Evaluation.run(info:)` itself takes no concurrency
/// limit, and the hermetic `CompactionEvalDispatchShapeTests` states what the
/// framework does today. So a tier of `sampleCount` samples costs about
/// `sampleCount` times one sample rather than less.
///
/// - Parameter sampleCount: How many samples the tier runs.
/// - Returns: The derived bound, in minutes.
func compactionEvalDerivedTimeLimitMinutes(forSamples sampleCount: Int) -> Double {
    (Double(sampleCount) * compactionEvalMeasuredDearestSampleSeconds
        + compactionEvalMeasuredModelLoadSeconds) / compactionEvalSecondsPerMinute
}

/// The wall-clock ceiling the DEFAULT gated tier's `@Test` runs under, in
/// minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:)`` at the seven seeds
/// of ``compactionEvalRepresentativeSubsetIDs``: 7 x 7.2 s plus 2.0 s is 52.4
/// seconds, which is 0.87 minutes, and one minute is the smallest limit Swift
/// Testing accepts. `CompactionEvalTierBarTests` holds this value against
/// that derivation from both sides, so a subset that outgrew its limit, or a
/// limit that stopped stating a measurement, fails a plain `swift test`
/// rather than a gated run.
///
/// The measured run behind the derivation is the gated subset run of
/// 2026-08-20 against ``CompactionEvalRealModel``, under task ^xx02yn6's
/// span-budget trim, whose whole wall clock was 38.2 seconds — the seconds
/// the derivation does not carry are the framework's own dispatch and
/// report, spent outside any sample's own trail. This limit is well inside
/// task ^k0d30s4's two-minute budget for every integration test. The 42
/// minutes this value stated before ^6ssbakk was derived from the 30B
/// model's 197.4-to-352.0-second samples, a rate the small-model swap
/// removed.
///
/// One thing can still spend the margin: a machine that has never fetched the
/// model pays that download inside this limit. Sampling cannot —
/// ``CompactionEvalRealSubjectRunner`` pins
/// ``FoundationModels/GenerationOptions/SamplingMode/greedy``, so two runs of
/// identical code generate the same answers at the same lengths (task
/// ^xscp198). A run that ends on the limit names the seeds it never reached —
/// see ``CompactionEvalFactRetentionReport/lines(of:expecting:)`` — so an
/// overrun reads as an overrun rather than as a smaller clean sheet.
let compactionEvalSubsetTimeLimitMinutes = 1

/// The wall-clock ceiling the opt-in whole-dataset tier's `@Test` runs under,
/// in minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:)`` at the whole
/// dataset's 24 seeds: 24 x 7.2 s plus 2.0 s is 174.8 seconds, which is 2.91
/// minutes. That charges EVERY sample at the dearest cost the subset run of
/// 2026-08-20 measured, so it is a bound rather than an expected cost. The
/// samples run one at a time whatever shape the framework dispatches,
/// because the runner holds a value-1 permit around one sample's whole run
/// (task ^23qeprz), so twenty-four samples cost about twenty-four times one
/// sample rather than less.
///
/// The tier itself is measured, not only derived: the gated whole-dataset
/// run of 2026-08-20 against ``CompactionEvalRealModel``, under task
/// ^xx02yn6's span-budget trim, measured a wall clock of 124.9 seconds over
/// all 24 seeds with none unreached. That run sits inside the 174.8-second
/// bound above — and past the 2 minutes this value stated before ^xx02yn6,
/// a limit the redesigned stage's condense re-asks outgrew: most folds now
/// make two summarizer calls, where the runs of 2026-08-19 measured 52.4 to
/// 53.6 seconds at one call each. This tier is the opt-in one, outside task
/// ^k0d30s4's two-minute budget for the everyday command, which skips it.
///
/// The 120 minutes this value stated before ^6ssbakk was derived from the
/// 30B model's 271.0-second mean sample, a rate the small-model swap
/// removed. `CompactionEvalTierBarTests` holds this tier to the same
/// dearest-rate derivation the subset tier is held to, which the two bases'
/// old disagreement made impossible.
let compactionEvalFullDatasetTimeLimitMinutes = 3

// MARK: - Measured tier bars

/// The mean SUMMARY fact retention a gated tier's samples must reach: the
/// share of folds whose summary carries the planted key phrase.
///
/// ## The small model's measured baseline, minus one sample of margin
///
/// The bar was 0.9 for both sides while the tiers drove the 30B model —
/// compaction_plan.md §5's own bar. Task ^k0d30s4's two-minute budget swapped
/// the subject for ``CompactionEvalRealModel``, and the bar follows the
/// subject: a bar the subject cannot reach measures the model rather than
/// the compaction prompt. The floor is the WEAKER tier's measured share
/// minus one sample of that tier's margin.
///
/// Task ^xx02yn6 re-measured both tiers under its span-budget trim and its
/// `router-default-v3` size-budget prompt, both designed against
/// Qwen3.8-27B (the standard model, which the redesign took from 0 of 7 to
/// 5 of 7 subset summaries). The small 1B canary moved the OTHER way under
/// the same prompt: the gated runs of 2026-08-20 under greedy decoding
/// measured 2 of 7 subset summaries and 13 of 24 whole-dataset summaries
/// carrying the fact, against 6 of 7 and 17 of 24 on 2026-08-19 under the
/// old prompt and per-call cut. The 1B overshoots the stated size budget on
/// most seeds, its answers enumerate background head-first, and the
/// last-resort cut then drops the facts stated later in the span — task
/// ^xx02yn6's card records the four-run trail. The weaker tier is now the
/// subset: 2 of 7 is 0.286, one sample under it is 1 of 7, and 0.14
/// requires exactly that 1 — and 4 of the whole dataset's 24 seeds, well
/// under its measured 13. The 0.65 this value stated before ^xx02yn6 was
/// the same rule over the 2026-08-19 measurements.
///
/// ## What a seed count makes of it
///
/// The metric scores one bit per sample, so a tier of `n` samples can only
/// produce the means `k/n`. The bar a tier really applies is the smallest `k`
/// whose `k/n` clears the floor:
///
/// | tier | seeds | summaries that must carry the fact | which is a mean of |
/// |---|---|---|---|
/// | the representative subset | 7 | 1 | 0.143 |
/// | the whole dataset | 24 | 4 | 0.167 |
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
let compactionEvalSummaryFactRetentionFloor = 0.14

/// The mean end-to-end `FactRetention` a gated tier's samples must reach: the
/// share of ANSWERS carrying the planted key phrase after the resumed session
/// reads the folded transcript.
///
/// Never above ``compactionEvalSummaryFactRetentionFloor``, and that order
/// is structural: an answer can only carry a fact its own transcript holds,
/// so the summary share bounds this one from above. The two sides carried
/// ONE number while the 30B model ran both near 0.9; the small model
/// separated them on 2026-08-19 (6 of 7 subset summaries against 5 of 7
/// subset answers, 17 of 24 whole-dataset summaries against 13 of 24
/// whole-dataset answers), so each side states its own floor: the weaker
/// tier's measured baseline minus one sample of that tier's margin.
///
/// Task ^xx02yn6's re-baseline of 2026-08-20 (see the summary floor above
/// for the whole story) measured 2 of 7 subset answers and 9 of 24
/// whole-dataset answers. The weaker tier is the subset: 2 of 7 is 0.286,
/// one sample under it is 1 of 7, and 0.14 requires exactly that 1 — and 4
/// of the whole dataset's 24 seeds, well under its measured 9. The two
/// sides meet at the same number here because the subset's summaries and
/// answers measured the same 2 of 7; the constants stay separate because
/// they state separate measurements. The 0.5 this value stated before
/// ^xx02yn6 was the same rule over the 2026-08-19 measurements.
let compactionEvalAnswerFactRetentionFloor = 0.14

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
///
/// The gated tiers now run ``CompactionEvalRealModel/ref``, the small Llama
/// model, and this value deliberately keeps the LARGER of the two tokenizers'
/// rates. Measured on 2026-08-19 with the `tokenizers` library over the Llama
/// 3.2 tokenizer out of the same Hub cache, against the single-line literals
/// of the two dataset sources: 8776 bytes against 1940 tokens, which is 4.524
/// bytes for each token. Every use of this constant converts a real-token
/// allowance into the bytes a real summary occupies, so the larger rate
/// over-states every such summary and each gate it feeds stays strict: the
/// hermetic shrink gate folds against a summary bigger than the model writes,
/// and the seed sizing outweighs a worst case bigger than the real one.
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
/// answer, and ``CompactionEvalRealModel/ref`` writes no such block, so the
/// default hands the small model thousands of tokens of free generation. The
/// gated subset run of 2026-08-19 measured what that freedom costs: two of
/// seven folds generated to the ceiling — 20485 and 16060 bytes of summary
/// answer — at 28.5 seconds each, where the five bounded folds cost 2.5 to
/// 7.4 seconds. The three fast compaction smoke suites cut the same value for
/// the same measured reason. Both gated eval tiers read this one constant, so
/// the two cannot drift.
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

