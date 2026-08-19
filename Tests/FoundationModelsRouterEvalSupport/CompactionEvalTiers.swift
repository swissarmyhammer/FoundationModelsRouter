import FoundationModels
import FoundationModelsRouter

// MARK: - Measured tier limits

/// The dearest of the samples the gated subset run of 2026-08-19 timed apart,
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
/// ``compactionEvalReasoningTokenHeadroom``. The seven samples cost 2.0, 1.9,
/// 1.9, 1.9, 2.0, 2.0 and 3.5 seconds; the dearest spent 1.7 of its 3.5 on an
/// answering turn that generated 1203 bytes. The 30B run of 2026-08-18
/// measured 197.4 to 352.0 seconds per sample over the same recipe, which is
/// the rate the two-minute budget removed.
///
/// The DEAREST sizes a limit, not the mean, because the spread between
/// samples is what a limit has to survive (task ^6ssbakk).
private let compactionEvalMeasuredDearestSampleSeconds = 3.5

/// What the same run's model load cost, in seconds.
///
/// ``CompactionEvalRealModelContainer/load(samplingMode:unexpectedContainerType:)``
/// times the load on its own two progress lines, so it is charged to no sample
/// and has to be added back when a whole tier is sized. The run of 2026-08-19
/// measured the small model's load at 2.0 seconds, where the 30B loaded in
/// 3.5 to 3.6 (tasks ^h2xxsse, ^6ssbakk).
private let compactionEvalMeasuredModelLoadSeconds = 2.0

/// How many seconds a minute holds.
///
/// The eval's progress lines measure in seconds and Swift Testing's
/// `.timeLimit(.minutes(_:))` takes whole minutes, so every derivation below
/// crosses this rate once.
private let compactionEvalSecondsPerMinute = 60.0

/// The wall clock a gated tier of `sampleCount` samples is bounded by, in
/// minutes, derived from the samples the gated run of 2026-08-19 timed apart.
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
func compactionEvalDerivedTimeLimitMinutes(forSamples sampleCount: Int) -> Double {
    (Double(sampleCount) * compactionEvalMeasuredDearestSampleSeconds
        + compactionEvalMeasuredModelLoadSeconds) / compactionEvalSecondsPerMinute
}

/// The wall-clock ceiling the DEFAULT gated tier's `@Test` runs under, in
/// minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:)`` at the seven seeds
/// of ``compactionEvalRepresentativeSubsetIDs``: 7 x 3.5 s plus 2.0 s is 26.5
/// seconds, which is 0.44 minutes, and one minute is the smallest limit Swift
/// Testing accepts. `CompactionEvalTierBarTests` holds this value against
/// that derivation from both sides, so a subset that outgrew its limit, or a
/// limit that stopped stating a measurement, fails a plain `swift test`
/// rather than a gated run.
///
/// The measured run behind the derivation is the gated subset run of
/// 2026-08-19 against ``CompactionEvalRealModel``, whose whole wall clock was
/// 36.3 seconds — the ~10 seconds the derivation does not carry are the
/// framework's own dispatch and report, spent outside any sample's own trail.
/// This limit is well inside task ^k0d30s4's two-minute budget for every
/// integration test. The 42 minutes this value stated before was derived from
/// the 30B model's 197.4-to-352.0-second samples (task ^6ssbakk), a rate the
/// small-model swap removed.
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
/// dataset's 24 seeds: 24 x 3.5 s plus 2.0 s is 86.0 seconds, which is 1.43
/// minutes. That charges EVERY sample at the dearest cost the subset run of
/// 2026-08-19 measured, so it is a bound rather than an expected cost, and it
/// sits inside task ^k0d30s4's two-minute budget. The samples generate one at
/// a time whatever shape a run takes, because MLX gives the resident
/// container serial access, so twenty-four samples cost about twenty-four
/// times one sample rather than less.
///
/// The tier itself is measured, not only derived: the gated whole-dataset
/// runs of 2026-08-19 against ``CompactionEvalRealModel`` measured wall
/// clocks of 52.5, 52.4 and 53.6 seconds, each over all 24 seeds with none
/// unreached (tasks ^k0d30s4, ^7fvthme). So the measured tier spends under
/// half of this limit and sits well inside the 86.0-second bound above,
/// which confirms the derivation from the tier's own end-to-end runs.
///
/// The 120 minutes this value stated before was derived from the 30B model's
/// 271.0-second mean sample (task ^6ssbakk), a rate the small-model swap
/// removed. `CompactionEvalTierBarTests` now holds this tier to the same
/// dearest-rate derivation the subset tier is held to, which the two bases'
/// old disagreement made impossible.
let compactionEvalFullDatasetTimeLimitMinutes = 2

// MARK: - Measured tier bars

/// The mean SUMMARY fact retention a gated tier's samples must reach: the
/// share of folds whose summary carries the planted key phrase.
///
/// ## The small model's measured baseline, minus one sample of margin
///
/// The bar was 0.9 for both sides while the tiers drove the 30B model —
/// compaction_plan.md §5's own bar. Task ^k0d30s4's two-minute budget swapped
/// the subject for ``CompactionEvalRealModel``, and the bar follows the
/// subject: the gated runs of 2026-08-19 under greedy decoding measured 6 of
/// 7 subset summaries and 17 of 24 whole-dataset summaries carrying the fact,
/// and a bar the subject cannot reach measures the model rather than the
/// compaction prompt. The floor is the WEAKER tier's measured share minus one
/// sample of margin: 17 of 24 is 0.708, one sample under it is 16 of 24, and
/// 0.65 requires exactly that 16 — and 5 of the 7 subset seeds, one under the
/// subset's measured 6.
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
/// | the whole dataset | 24 | 16 | 0.667 |
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
let compactionEvalSummaryFactRetentionFloor = 0.65

/// The mean end-to-end `FactRetention` a gated tier's samples must reach: the
/// share of ANSWERS carrying the planted key phrase after the resumed session
/// reads the folded transcript.
///
/// Lower than ``compactionEvalSummaryFactRetentionFloor``, and that order is
/// structural: an answer can only carry a fact its own transcript holds, so
/// the summary share bounds this one from above. The two sides carried ONE
/// number while the 30B model ran both near 0.9. The small model separates
/// them — the gated runs of 2026-08-19 measured 6 of 7 subset summaries
/// against 5 of 7 subset answers, and 17 of 24 whole-dataset summaries
/// against 13 of 24 whole-dataset answers; the debugging trail of the
/// continuity tier shows the same shape: the model's answering turn refuses
/// or paraphrases identifiers its own fold summary carries verbatim. One
/// number can no longer serve both sides honestly, so each side states the
/// weaker tier's measured baseline minus one sample of margin: 13 of 24 is
/// 0.542, one sample under it is 12 of 24, and 0.5 requires exactly that 12 —
/// and 4 of the 7 subset seeds, one under the subset's measured 5.
let compactionEvalAnswerFactRetentionFloor = 0.5

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
/// PRODUCTION defaults: ``Summarization/minimumSummaryTokens`` — the
/// allowance every seed's span earns — plus
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
/// allowance, and deliberately not ``Summarization``'s own default of 4096.
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
struct RealisticSummaryLengthSummarizer: CompactionSummarizer {
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

