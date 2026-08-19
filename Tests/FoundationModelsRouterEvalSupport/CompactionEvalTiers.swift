import FoundationModels
import FoundationModelsRouter

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
func compactionEvalDerivedTimeLimitMinutes(forSamples sampleCount: Int) -> Double {
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
let compactionEvalFactRetentionFloor = 0.9

/// The smallest number of a tier's samples that must retain the fact for the
/// tier's mean to clear ``compactionEvalFactRetentionFloor``.
///
/// Found by the same `>=` comparison ``expectFactRetention(of:)`` applies to its
/// SUMMARY share, over the counts a tier can really produce, so this arithmetic
/// and that one assertion can never disagree.
///
/// The guarantee reaches that assertion and no further, because the two sides
/// read different recordings on purpose. The answer side reads the Evaluations
/// framework's own `.mean(of:)` rather than
/// ``CompactionEvalFactRetentionReport/share(of:over:)``, so the tier's
/// end-to-end verdict IS the framework's verdict rather than a second derivation
/// of it that could drift from the metric it reports. The floor and the `>=` are
/// the same on both sides, so the bar is the same; what differs is which
/// recording each share is taken over (task ^xscp198).
///
/// Computing `ceil(floor * n)` instead would disagree: the nearest `Double` to
/// 0.9 is a shade above 0.9, so `ceil(0.9 * 10)` is 10 where 9 of 10 already
/// clears the bar.
///
/// - Parameter sampleCount: How many samples the tier runs.
/// - Returns: The smallest count that clears the floor. `0` for a tier of no
///   samples, which has no count to reach; `sampleCount` for a floor above 1.0,
///   which no count clears.
func compactionEvalFactRetentionRequiredSamples(of sampleCount: Int) -> Int {
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

