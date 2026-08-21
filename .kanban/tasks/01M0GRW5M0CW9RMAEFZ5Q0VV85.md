---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0hffa62jft1exmg7zf5hemr
  text: |-
    Research done. The whole-dataset tier's own per-sample trail EXISTS already, so no new GPU run is necessary.

    The gated whole-dataset run of 2026-08-20 (Qwen2.5-3B-Instruct-4bit, greedy, headroom 128, `router-default-v3` prompt with the span-budget trim) is in the shell history. Each sample's own cost is its `answer returned elapsed=` value, because `elapsed` counts from `sampleStartedAt` and the run drives one sample at a time. The 24 samples cost, in dataset order:

    11.0, 5.4, 5.1, 3.8, 4.7, 12.2, 3.2, 4.1, 5.9, 5.1, 4.3, 3.3, 4.2, 6.6, 11.0, 3.9, 3.8, 56.5, 24.3, 23.0, 82.4, 27.6, 11.5, 44.7 seconds.

    They add to 367.6 s. Plus the 1.3 s model load that is charged to no sample, that is 368.9 s against the 369.1 s wall clock the run reported. So the trail is complete and it is not a division.

    The DEAREST is 82.4 s, at sample 21, seed `three-facts-support-escalation`.

    Discovery that corrects this card's own stated cause. The card says "The subset's seven seeds are cheap seeds, and the seeds only the whole dataset holds are dear ones." That is FALSE. `three-facts-support-escalation` IS one of the subset's seven seeds. The subset run of the same day measured that same seed at 15.9 s as its sample 7; the whole-dataset run measured it at 82.4 s as its sample 21. The work is identical in the two runs — `summarizerCalls=2` and `summarizerBytes=1948` in both, which greedy decoding makes repeatable — so the 5.2x is throughput, not more work. The same holds for `three-facts-long-project-brief`: 15.9 s at sample 6 of the subset, 56.5 s at sample 18 of the whole dataset, `summarizerCalls=2` and `summarizerBytes=2103` in both.

    So a tier's per-sample rate is a property of the RUN LENGTH, not of the seeds. That is a stronger reason for the card than the one filed: no seed selection can make one tier's rate bound another tier's samples, so each tier must carry its own measured rate.

    The derivation this gives, in the shape `compactionEvalDerivedTimeLimitMinutes(forSamples:)` already states: 24 x 82.4 s + 1.3 s = 1978.9 s = 32.98 minutes, so the next whole minute above is 33.

    On card ^k0d30s4's open question, which only the user settles: this work survives BOTH answers, but only one of them keeps it useful. The tier exists today and its stated limit of 7 minutes is wrong today, so correcting the derivation is worth doing now. If the user later deletes the tier, this change is deleted with it and costs nothing. I do not decide that question and I change nothing about which tiers exist.
  timestamp: 2026-08-21T06:17:31.074055+00:00
- actor: claude-code
  id: 01m0hfw68hw83kh2hd02wnezsg
  text: |-
    ### implement — changed

    - evidence: 2 source files — `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift` and `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`.
    - derivation: the whole-dataset tier now charges its own measured dearest sample. 24 x 82.4 s + 1.3 s = 1978.9 s = 32.98 minutes, so `compactionEvalFullDatasetTimeLimitMinutes` is 33 in place of 7. The subset tier is unchanged: 7 x 15.9 s + 1.3 s = 112.6 s = 1.88 minutes, so `compactionEvalSubsetTimeLimitMinutes` stays 2, inside ^k0d30s4's two-minute budget.
    - shape: `compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)` is still the one arithmetic and now takes the rate. `compactionEvalMeasuredDearestSampleSeconds` is two named rates: `compactionEvalSubsetMeasuredDearestSampleSeconds` (15.9) and `compactionEvalFullDatasetMeasuredDearestSampleSeconds` (82.4), each internal so the tier bar tests can name them. `compactionEvalMeasuredModelLoadSeconds` stays shared at 1.3, the larger of the two measured loads, so it over-states for both tiers.
    - TDD: with the rate parameter in place and the limit still 7, `swift test --filter CompactionEvalTierBarTests` FAILED — "a tier of 24 seeds at 82.4 s for each sample derives 32.98166666666667 minutes, against a limit of 7". The limit of 33 makes all 5 tests pass. Both sides bind: a probe at 34 fails the upper-side test ("states 34, which is more than the next whole minute above it"), and the failure at 7 above is the lower side. The probe was restored.
    - no gated run: none was necessary. The whole-dataset run of 2026-08-20 printed each sample's own cost and the 24 figures add to 367.6 s, which with the 1.3 s load is 368.9 against that run's 369.1 s of wall clock. No GPU time was spent, and no time limit was raised for a measurement.
    - builds: `swift build --build-tests -Xswiftc -warnings-as-errors` gives `Build complete!` at the root and in `IntegrationTests`, with no error and no warning.
    - tests: root `swift test` gives `Test run with 1025 tests in 96 suites passed ... with 1 known issue`, plus `Test run with 77 tests in 9 suites passed`.
    - dead code: `periphery scan --skip-build --index-store-path .build/out --retain-public` reports nothing in `CompactionEvalTiers.swift`, so the two new internal rates are seen as live through their use in the eval test target.
    - filed: ^epapxbk, for the cause behind this card. The same seed at the same work costs 15.9 s early in a run and 82.4 s late in one, so the tiers lose about 5x of throughput as a run goes on. That is why the bound is 5.4 times the measurement, and it may be a product defect rather than a property of the box.
    - not decided, and not touched: ^k0d30s4's question of whether this tier is deleted or kept as the opt-in tier. Only the user settles it.
    - next: `/review`.
  timestamp: 2026-08-21T06:24:33.041754+00:00
- actor: claude-code
  id: 01m0hg7t4akbh9mgmpsw102rsw
  text: |-
    ### review — clean
    - evidence: `review sha 59ca3b5~1..59ca3b5`, 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 2 Swift files reviewed; the 8 `.kanban` files are excluded by `.reviewignore`. The card moved from `doing` to `done`.
    - arithmetic, checked against the constants the files really hold: `compactionEvalFullDatasetMeasuredDearestSampleSeconds` = 82.4, `compactionEvalSubsetMeasuredDearestSampleSeconds` = 15.9, `compactionEvalMeasuredModelLoadSeconds` = 1.3, `compactionEvalSecondsPerMinute` = 60. Whole dataset: 24 x 82.4 + 1.3 = 1978.9 s = 32.9817 minutes, so 33 is correct. Subset: 7 x 15.9 + 1.3 = 112.6 s = 1.8767 minutes, so 2 is correct.
    - the two sums reconcile: the 24 stated sample costs add to 367.6 s, and with the 1.3 s load that is 368.9 s against the 369.1 s the run reported. The seven subset costs add to 62.3 s, and with the 1.2 s subset load that is 63.5 s against the 63.5 s that doc states. The corrected 12.1 s third subset sample keeps that sum true.
    - `CompactionEvalTierBarTests` holds each tier from the two sides, as the card states. The lower test asks `Double(limit) >= derived` and the upper test asks `Double(limit) < max(derived, 1) + 1`. For the whole dataset: 7 >= 32.98 is false, so 7 is red; 34 < 33.98 is false, so 34 is red; 33 satisfies both, so 33 is green. The subset is bound the same way: 1 is red below, 3 is red above, 2 is green.
    - `swift test --filter CompactionEvalTierBarTests`: 5 tests in 1 suite passed. No gated real-model suite was run.
    - judgement on the size of the limit: the 33 minutes does useful work, but only as a stop for a hung run. At 5.4 times the 369.1 s the tier measures, it cannot find a rate regression, because a run that costs twice as much still clears it. The work of finding rate drift is done by `CompactionEvalTierBarTests`, which goes red as soon as a measured rate constant stops agreeing with the stated limit. The size is the necessary result of the standing rule that a tier must never REACH its limit (^3axg80k), together with the 3.2 to 82.4 s spread that ^epapxbk holds. I do not disagree with the change: 7 was unsafe, and 33 is the honest bound of the samples this tier measured. No finding.
    - next: none. Card ^k0d30s4 still holds the open question of whether this tier is kept or deleted, and this card does not decide it.
  timestamp: 2026-08-21T06:30:53.834519+00:00
- actor: claude-code
  id: 01m0hg8sgcrc6h80ntkt3cr125
  text: |-
    ### finish iteration — clean
    - implement: changed — 2 source files; each tier's limit now derives from that tier's OWN measured rate: the whole dataset at 24 x 82.4 s plus 1.3 s gives 33 minutes, and the subset stays 2. No GPU time was spent, because the run of 2026-08-20 already printed each sample's cost
    - test: green — `CompactionEvalTierBarTests` binds both tiers from both sides; root swift test 1025 in 96 suites plus 77 in 9 suites; both packages build with -warnings-as-errors
    - commit: 59ca3b5
    - review: clean — 0 findings; the reviewer re-derived every stated number and confirmed the bar goes red at 7 and at 34 and green at 33; task moved to `done`
    - filed: ^epapxbk — the same seed measured 15.9 s in the subset run and 82.4 s in the whole-dataset run on one day at identical work, so throughput falls with run length
  timestamp: 2026-08-21T06:31:25.964596+00:00
position_column: done
position_ordinal: ffdb80
title: Give the whole-dataset compaction eval tier a bound its own measured samples derive
---
`compactionEvalFullDatasetTimeLimitMinutes` is derived from the SUBSET run's dearest sample (`compactionEvalMeasuredDearestSampleSeconds`, 15.9 s under Qwen2.5-3B-Instruct), multiplied by the whole dataset's 24 seeds. Task ^m03heaa measured the whole-dataset tier and found that the derivation, which is supposed to be a bound, is close to the truth by luck only:

- Derived bound: 24 x 15.9 s + 1.3 s = 382.9 s.
- Measured wall clock on 2026-08-20: 369.1 s.
- Margin: 13.8 s, which is 3.6 percent.
- The run's late samples cost far MORE than the subset's dearest: up to 82.4 s at sample 21, against 15.9 s for the dearest of the seven subset samples.

So the per-sample cost is not flat across the run. The subset's seven seeds are cheap seeds, and the seeds only the whole dataset holds are dear ones. A bound built from the cheap seeds does not bound the dear ones; the two errors cancelled this time.

That matters because a gated run must never reach its time limit. A run that reaches it takes a Metal abort (signal 6 or 11) — see fork card ^3axg80k — so the tier does not fail, it crashes.

## What to build

- Time each of the 24 whole-dataset samples apart, from the tier's own progress lines, as `compactionEvalMeasuredDearestSampleSeconds` is timed for the subset.
- Give the whole-dataset tier its own measured dearest-sample constant, and derive its limit from that, so each tier's bound rests on its own samples.
- Keep `compactionEvalDerivedTimeLimitMinutes(forSamples:)` as the one shared arithmetic; give it the rate to charge, rather than reading one global rate.
- Extend `CompactionEvalTierBarTests` so each tier is held to its own rate.

## Acceptance Criteria

- [x] The whole-dataset tier's time limit is the next whole minute above a bound derived from the whole-dataset tier's OWN measured dearest sample
- [x] The subset tier's limit still derives from the subset's own dearest sample, and stays inside task ^k0d30s4's two-minute budget
- [x] `CompactionEvalTierBarTests` holds both tiers against their own rates, from both sides
- [x] The doc comment of each measured constant names the run it was measured on

## What landed, 2026-08-21

No new GPU run was necessary. The whole-dataset run of 2026-08-20 printed each sample's own cost, and that trail is complete: the 24 samples add to 367.6 s, and with the 1.3 s model load that no sample carries that is 368.9 s against the 369.1 s wall clock the run reported.

**The measured rate.** The 24 samples cost 11.0, 5.4, 5.1, 3.8, 4.7, 12.2, 3.2, 4.1, 5.9, 5.1, 4.3, 3.3, 4.2, 6.6, 11.0, 3.9, 3.8, 56.5, 24.3, 23.0, 82.4, 27.6, 11.5 and 44.7 seconds, in dataset order. The dearest is 82.4 s, at sample 21, seed `three-facts-support-escalation`.

**The derivation.** 24 x 82.4 s + 1.3 s = 1978.9 s = 32.98 minutes, so `compactionEvalFullDatasetTimeLimitMinutes` is 33 in place of 7. `compactionEvalSubsetTimeLimitMinutes` stays 2, from 7 x 15.9 s + 1.3 s = 112.6 s = 1.88 minutes.

**The shape of the code.** `compactionEvalDerivedTimeLimitMinutes(forSamples:chargedAt:)` is still the one arithmetic, and it now takes the rate to charge. The one global rate is two named rates: `compactionEvalSubsetMeasuredDearestSampleSeconds` (15.9) and `compactionEvalFullDatasetMeasuredDearestSampleSeconds` (82.4). `compactionEvalMeasuredModelLoadSeconds` stays shared at 1.3, which is the larger of the two measured loads, so it over-states for both tiers. `CompactionEvalTierBarTests.tierLimits` carries each tier's rate beside its limit and its seed count, and both time-limit tests charge each tier at its own rate.

**One correction to this card's own stated cause.** The card says the seeds only the whole dataset holds are the dear ones. That is not what the trail shows. `three-facts-support-escalation`, the dearest sample of the whole-dataset run at 82.4 s, IS one of the subset's seven seeds, and the subset run measured it at 15.9 s the same day. `three-facts-long-project-brief` is the same story: 15.9 s in the subset run, 56.5 s in the whole-dataset run. Each seed did the SAME work in both runs — two summarizer calls, and 1948 and 2103 summary bytes, which greedy decoding repeats — so the difference is throughput, not more work. The rate a tier is charged is a property of the tier's own LENGTH, which is a stronger reason for this card than the one filed: no seed selection can make one tier's rate bound another tier's samples. The falling throughput itself is filed as its own card, ^epapxbk.

**What the new limit states, and what it does not.** The bound is 5.4 times the 369.1 s the tier measures, because it charges every sample at the dearest and this tier's samples spread from 3.2 to 82.4 s inside one run. That distance is the honest consequence of the standing rule: a tier must never REACH its limit, because a run that reaches one takes a Metal abort in place of a failure (^3axg80k). Card ^epapxbk holds the question of whether the spread itself can be removed, which would take the bound back down.

**Card ^k0d30s4's open question is untouched.** Whether this tier is deleted or kept as the declared opt-in tier is the user's decision and no part of this work. This card corrects a limit that is wrong today on a tier that exists today. If the tier is deleted later, this change goes with it.

**Also corrected, from the same trail.** The doc of the subset rate stated the third subset sample at 12.2 s. The subset run's own line reads 12.1 s (the 12.2 is that seed's cost in the whole-dataset run). The dearest is unchanged, so no derived value moves. #compaction #eval #real-model