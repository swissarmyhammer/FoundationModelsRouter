import FoundationModels
import FoundationModelsRouter

// MARK: - Measured tier limits

/// The dearest of the samples the gated subset run of 2026-08-20 timed apart,
/// in seconds.
///
/// One sample's own work — its compaction and its answering turn together — read off
/// that sample's own progress lines. Never a run's wall clock divided by a
/// sample count: `^9cw5g6n` forbids that division, and this trail makes it
/// unnecessary, because the run drove its samples one at a time and printed
/// each sample's four lines complete before the next sample's first line.
///
/// Measured against ``CompactionEvalRealModel`` — Qwen2.5-3B-Instruct since
/// task ^m03heaa put it in place of the 1B canary — under task ^xx02yn6's
/// `router-default-v3` prompt, at greedy decoding. That run predates task
/// ^pke18c2, which made the compaction one summarizer call: the compaction
/// of that day could make a second call on a long answer, and it did on
/// three of the seven samples. The one-call compaction makes one call on
/// every sample, so this rate is an upper bound for it until the tier is
/// measured again. The seven samples cost 5.4, 4.7, 12.1, 3.2, 5.1, 15.9 and
/// 15.9 seconds. The rate rose from the
/// 7.2-second dearest sample the 1B canary measured over the same recipe on
/// the same day, which is what a model of three times the parameters costs to
/// decode. The 30B run of 2026-08-18 measured 197.4 to 352.0 seconds per
/// sample over the same recipe, which is the rate the two-minute budget
/// removed.
///
/// Every one of those seven samples APPLIED its compaction, and that is half of the
/// cost each figure holds: the answering turn then reads the compacted
/// transcript. Task ^azd033m made the compaction apply. Before that change a compaction
/// was discarded, and a discarded compaction costs one summarizer call and nothing
/// after it, so a rate measured over discarded compactions under-states this one —
/// which is why the 7-sample run of 2026-08-17 is not comparable with any
/// figure above. The run of 2026-08-20 filed six of its seven samples as
/// `retained` and one as `summaryLostFact`, and none as
/// ``CompactionEvalFactRetentionClass/compactionProducedNoSummary``, which is how
/// its own trail shows that each compaction applied. Ungated tests keep the
/// property true without a gated run.
/// `CompactionEvaluationHermeticTests/everySeedCompactionSurvivesARealisticSummary`
/// compacts every seed against ``StatedSizeSummarizer``, which answers with
/// the whole size the prompt states. `CompactionEvalSeedSizingTests` holds
/// the arithmetic behind it: `everySeedIsOverTheTarget` holds every seed over
/// the default budget's target, `targetLeavesRoomAfterTheInstructions` holds
/// the stated size above zero, and `everySeedsCallFitsTheGatedWindow`
/// holds each call inside ``CompactionEvalRealModel/context``. So a summary
/// that keeps to the stated size cannot fail `Compactor.compact`'s
/// did-not-shrink check (task ^6ssbakk).
///
/// The DEAREST sizes a limit, not the mean, because the spread between
/// samples is what a limit has to survive (task ^6ssbakk).
///
/// This rate sizes THIS tier and no other, and that is not a formality. A
/// second gated tier compacted all 24 fixtures the dataset then held, until task
/// ^k0d30s4 cut the dataset to these seven, and the two runs of 2026-08-20
/// measured seeds BOTH tiers held at two different rates.
/// `three-facts-support-escalation` cost 15.9 seconds as sample 7 of the
/// seven-sample run and 82.4 seconds as sample 21 of the twenty-four-sample
/// one; `three-facts-long-project-brief` cost 15.9 seconds as sample 6 here and
/// 56.5 seconds as sample 18 there. Each seed did the SAME work in both runs —
/// two summarizer calls under the compaction of that day, which predates task
/// ^pke18c2, and 1948 and 2103 summary bytes, which greedy decoding
/// repeats — so what changed is throughput, and a rate measured over a short
/// run cannot bound a long one (task ^5q0vv85). That is why
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)`` charges the
/// rate its CALLER states rather than reading one global rate: a tier of
/// another length has to measure its own before it can be bounded.
let compactionEvalSubsetMeasuredDearestSampleSeconds = 15.9

/// What the two runs of 2026-08-20 measured the model load at, in seconds.
///
/// ``CompactionEvalRealModelContainer/load(ref:context:samplingMode:unexpectedContainerType:)``
/// times the load on its own two progress lines, so it is charged to no sample
/// and has to be added back when a whole tier is sized. The two runs of
/// 2026-08-20 measured Qwen2.5-3B's load at 1.2 seconds on the seven-seed tier
/// and 1.3 on the twenty-four-seed tier task ^k0d30s4 deleted, where the 1B
/// canary it replaced loaded in 1.8 to 2.0 and the 30B loaded in 3.5 to 3.6
/// (tasks ^h2xxsse, ^6ssbakk). The larger of the two measured loads of the
/// current subject is kept, so the derived bound never under-states.
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
/// reads. A rate measured over a short run does not bound a long one: the two
/// runs of 2026-08-20 measured two seeds that BOTH gated tiers then held at
/// 15.9 seconds each in the seven-sample run, and at 82.4 and 56.5 seconds in
/// the twenty-four-sample one, for the same work at greedy decoding (task
/// ^5q0vv85). One tier is left, and it states its own measured rate in
/// ``compactionEvalSubsetMeasuredDearestSampleSeconds``; a tier of another
/// length would have to measure its own and hand it here, which a global
/// constant would let it skip.
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

/// The wall-clock ceiling the gated fact-retention tier's `@Test` runs under,
/// in minutes.
///
/// The next whole minute above
/// ``compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)`` at the
/// seven seeds of ``compactionEvalRepresentativeSubsetIDs``, charged at this
/// tier's OWN measured rate,
/// ``compactionEvalSubsetMeasuredDearestSampleSeconds``: 7 x 15.9 s plus 1.3 s
/// is 112.6 seconds, which is 1.88 minutes, so this states 2.
/// `CompactionEvalTierBarTests` holds this value against
/// that derivation from both sides, so a dataset that outgrew this limit, or a
/// limit that stopped stating a measurement, fails a plain `swift test`
/// rather than a gated run.
///
/// The measured run behind the derivation is the gated subset run of
/// 2026-08-20 against ``CompactionEvalRealModel``, under task ^xx02yn6's
/// prompt and before task ^pke18c2, whose whole wall clock was 63.5 seconds — the seconds
/// the derivation does not carry are the framework's own dispatch and
/// report, spent outside any sample's own trail. That measured 63.5 seconds
/// is inside task ^k0d30s4's two-minute budget for every integration test,
/// which is the property task ^m03heaa had to keep while it changed the
/// canary, and the limit of 2 minutes states the same budget.
///
/// One run states no spread. The same tier, on the same box, measured 89.0
/// seconds of suite wall clock on 2026-08-21 with the same 6 of 7 on each side
/// and no seed unreached, which is 74 percent of this limit. The derivation
/// above covers it: 89.0 sits under the 112.6 seconds every sample at the
/// dearest measured rate would cost. A tier must never REACH its limit, because
/// a run that reaches one takes a Metal abort in place of a failure (fork card
/// ^3axg80k), so the limit covers the run in which every sample lands where the
/// dearest landed rather than the run that has been measured. The 1 minute
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
/// see ``CompactionEvalFactRetentionReport/lines(of:expecting:counter:)`` — so an
/// overrun reads as an overrun rather than as a smaller clean sheet.
let compactionEvalSubsetTimeLimitMinutes = 2

// MARK: - Measured tier bars

/// The mean SUMMARY fact retention a gated tier's samples must reach: the
/// share of compactions whose summary carries the planted key phrase.
///
/// ## The canary's measured baseline, minus one sample of margin
///
/// The bar was 0.9 for both sides while the gated tiers drove the 30B model —
/// compaction_plan.md §5's own bar. Task ^k0d30s4's two-minute budget swapped
/// the subject for ``CompactionEvalRealModel``, and the bar follows the
/// subject: a bar the subject cannot reach measures the model rather than
/// the compaction prompt. The floor is the tier's measured share minus one
/// sample of its margin.
///
/// Task ^m03heaa re-measured against the canary it chose, Qwen2.5-3B-Instruct,
/// under task ^xx02yn6's `router-default-v3` size-budget prompt, at greedy
/// decoding, before task ^pke18c2 made the compaction one call. The gated
/// runs of 2026-08-20
/// measured 6 of the 7 summaries of this tier carrying the fact, and 23 of 24
/// on the wider tier ^k0d30s4 later deleted. One sample under each is 5 of 7,
/// which is 0.714, and 22 of 24, which is 0.917, so the seven-seed tier was
/// the weaker of the two and this floor comes from its 5 of 7. It is written
/// as 0.71, which sits under 5/7 and over 4/7, so the tier must retain exactly
/// those 5.
///
/// The 0.14 this value stated before ^m03heaa was the same rule over the 1B
/// canary that ran here until then: task ^xx02yn6's prompt redesign, built
/// for Qwen3.8-27B (the standard model, which the redesign took from 0 of 7
/// to 5 of 7 subset summaries), took the 1B the OTHER way, from 6 of 7 to 2
/// of 7 subset summaries and from 17 of 24 to 13 of 24 whole-dataset ones.
/// The 1B overshoots the stated size budget on most seeds and writes about
/// the background first, so the summary the compaction of that day stored
/// lost the facts stated later in the span. A floor of 0.14 asked 1 of the subset's 7
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
/// | the gated fact-retention tier | 7 | 5 | 0.714 |
///
/// ``compactionEvalFactRetentionRequiredSamples(of:floor:)`` computes that,
/// `CompactionEvalTierBarTests` holds it, and ``expectFactRetention(of:)``
/// states it in the message of a failing run — so a dataset whose size cannot
/// express the bar can no longer be chosen silently (task ^xscp198).
///
/// A bar with no tolerance is only worth having against a measurement that
/// does not move on its own. That is why ``CompactionEvalRealSubjectRunner``
/// pins ``FoundationModels/GenerationOptions/SamplingMode/greedy``: argmax
/// decoding consumes no randomness, so a run's score is a fact about the
/// prompt and the fixtures, and a drop under this floor is a regression in
/// the compaction rather than a draw.
let compactionEvalSummaryFactRetentionFloor = 0.71

/// The mean end-to-end `FactRetention` a gated tier's samples must reach: the
/// share of ANSWERS carrying the planted key phrase after the resumed session
/// reads the compacted transcript.
///
/// Never above ``compactionEvalSummaryFactRetentionFloor``, and that order
/// is structural: an answer can only carry a fact its own transcript holds,
/// so the summary share bounds this one from above. The two sides carried
/// ONE number while the 30B model ran near 0.9; the 1B canary separated them
/// on 2026-08-19 (6 of 7 summaries against 5 of 7 answers here, and 17 of 24
/// against 13 of 24 on the wider tier of the day), so each side states its own
/// floor: the measured baseline minus one sample of margin.
///
/// Task ^m03heaa's re-baseline of 2026-08-20 under Qwen2.5-3B-Instruct (see
/// the summary floor above for the whole story) measured 6 of the 7 answers of
/// this tier, and 23 of 24 on the wider tier ^k0d30s4 later deleted. One sample
/// under each is 5 of 7, which is 0.714, and 22 of 24, which is 0.917, so the
/// seven-seed tier was the weaker of the two and this floor comes from its 5 of
/// 7. Written as 0.71, it asks 5 of this tier's 7 seeds.
///
/// The two sides meet at the same number here because the 3B canary answered
/// with the fact on every seed whose summary carried it; the constants stay
/// separate because they state separate measurements. The 0.14 this value
/// stated before ^m03heaa was the same rule over the 1B canary's 2 of 7
/// answers.
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
/// The fixtures are sized in the tokens the model really counts, and this is
/// the rate between those tokens and the bytes of prose a fixture holds.
/// A compaction states the size of its summary in tokens, and a fixture is
/// written as bytes of prose. A fixture sized by a character
/// count in place of a tokenizer is exactly how
/// `CompactionRoundTripIntegrationTests` ended up below its own trigger (task
/// ^wnj3ka3), so this dataset is sized in the tokens the model really counts.
///
/// The corpus is this dataset's whole prose — every fixture's
/// ``CompactionEvalFixtureSpec/context`` and facts, every acknowledgement, and
/// every ``compactionEvalFillerTurns`` prompt and reply. That is 41 pieces of
/// text and 9824 UTF-8 bytes. Each piece is encoded on its own and the token
/// counts are summed, over each model's own `tokenizer.json` out of the local
/// Hub cache:
///
/// | tokenizer | tokens | bytes for each token |
/// |---|---|---|
/// | Muse Glimmer 30B | 2055 | 4.781 |
/// | Llama 3.2 1B | 2066 | 4.755 |
/// | Qwen2.5 3B | 2074 | 4.737 |
///
/// This value deliberately keeps the LARGEST of those rates, rounded up, so
/// the summary sizes it feeds are never under-stated.
///
/// The rate is a property of the prose the dataset HOLDS, so each edit to a
/// fixture measures it again by the same method. Task ^rdsbf57 rewrote the
/// head of one fixture, `env-file`, into `sesame-allergy`, and the rate fell
/// from 4.85 to 4.79: before that edit the corpus was 41 pieces and 9946 bytes,
/// and gave 2052, 2061 and 2069 tokens, thus 4.847, 4.826 and 4.807 bytes for
/// each token. Before ^rdsbf57, task ^k0d30s4 had cut the dataset from 24
/// fixtures to seven, and the rate rose from 4.81 to 4.85: the 24-fixture
/// corpus was 85 pieces and 31541 bytes, and gave 6564, 6577 and 6602 tokens,
/// thus 4.805, 4.796 and 4.777 bytes for each token. Each tokenizer read the
/// seven fixtures a shade less densely than it read all 24, and reads the
/// cooking prose of `sesame-allergy` more densely than the configuration prose
/// it replaced. Task ^m03heaa measured the Qwen2.5-3B row when that model
/// became the fact-retention canary; the 3B is the smallest of the three, so
/// that measurement did not move the constant. The 4.524 this doc stated for
/// the Llama tokenizer before ^m03heaa was taken over a different corpus — the
/// single-line literals of the two dataset sources, 8776 bytes against 1940
/// tokens — which is why the table above re-states it.
///
/// Every use of this constant converts real tokens into the bytes of prose
/// they occupy, so the largest rate over-states every such size and each gate
/// it feeds stays strict.
let compactionEvalMeasuredBytesPerToken = 4.79

/// A summarizer whose answer is the size the compaction states for it.
///
/// A stub answering `"fake summary"` shrinks a compaction whatever the seed
/// holds, so it proves the compaction REACHED its summarizer call and nothing
/// about whether the compaction survived the did-not-shrink check. The gated
/// run of 2026-08-17 discarded 8 of the 9 compactions the stub suite reported
/// as reaching the call (task ^vjf3mdm).
///
/// The compaction states the size the summary may take, in the tokens its
/// counter counts, in the assembled prompt: `Size budget: about N tokens.`
/// This summarizer reads that number and answers with that many characters.
/// Under the hermetic counter, which counts one token for each character,
/// that is an answer that fills the whole stated size: the largest answer a
/// WELL-BEHAVED summarizer writes. A seed that clears the shrink check against
/// this answer clears it against every answer that keeps to the stated size.
struct StatedSizeSummarizer: CompactionSummarizer {
    /// The words of the assembled prompt in front of the stated size.
    private static let statedSizeOpening = "Size budget: about "

    /// One sentence in the register a compaction summary is written in,
    /// repeated to reach the stated size. ASCII throughout, so one character
    /// is one byte.
    private static let sentence =
        "The conversation above stated a constraint the next turn has to keep, so this summary records it in the order it was given. "

    /// Answers with as many characters as `prompt` states for the summary.
    ///
    /// - Parameters:
    ///   - prompt: The assembled compaction prompt.
    ///   - maxTokens: The output ceiling of the call. This summarizer does not
    ///     read it: the stated size, not the ceiling, sets its answer.
    /// - Returns: ``sentence`` repeated and cut to the stated size, or the
    ///   empty string when the prompt states no size.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let characters = Self.statedSize(in: prompt)
        var text = ""
        while text.count < characters {
            text += Self.sentence
        }
        return String(text.prefix(characters))
    }

    /// The summary size `prompt` states, or `0` when it states none.
    ///
    /// - Parameter prompt: The assembled prompt.
    /// - Returns: The stated size, in tokens.
    private static func statedSize(in prompt: String) -> Int {
        guard let opening = prompt.range(of: statedSizeOpening) else { return 0 }
        return Int(prompt[opening.upperBound...].prefix { $0.isNumber }) ?? 0
    }
}

