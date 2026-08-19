---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dr6h1h4jg5qp0asvgydne0
  text: |-
    Commit efd3b58 (task ^k0d30s4) repaired this defect before this card started. That commit moved the gated tiers to the small model and made new derivations. The evidence from the source and from one run follows.

    Criterion 1 — one rule sizes the two limits. `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift` derives the two limits with one function, `compactionEvalDerivedTimeLimitMinutes(forSamples:)`. The function charges each sample at the dearest measured sample (3.5 s) and adds one model load (2.0 s). The subset limit is 1 minute (7 x 3.5 s + 2.0 s = 26.5 s = 0.44 min, and 1 minute is the smallest limit Swift Testing accepts). The whole-dataset limit is 2 minutes (24 x 3.5 s + 2.0 s = 86.0 s = 1.43 min). The card's 30B numbers (271.0 s mean, 352.0 s dearest, 140.8 min) do not apply now, because the tiers no longer drive the 30B model.

    Criterion 2 — the bar test holds the two tiers. `CompactionEvalTierBarTests.tierLimits` in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` holds the subset pair AND the whole-dataset pair. The two time-limit tests loop over that list and hold each limit from two sides: the limit must be at or above its derived bound, and the limit must be below the next whole minute above that bound.

    Run evidence. I ran the whole-dataset tier one time: `Scripts/swift-test.sh --filter CompactionEvalFullDataset` passed in 52.4 s of suite wall clock against the 120 s limit. All 24 seeds ran (`unreached: <none>`). Retention agreed with the recorded baselines: summary 17 of 24, answer 13 of 24.

    No code change was necessary. The card's option 1 (one rule for the two tiers) is what efd3b58 put in place, and option 3 (time the tier) now has a measurement: 52.4 s.
  timestamp: 2026-08-19T19:33:02.641224+00:00
- actor: claude-code
  id: 01m0dr6wdn6smdysr14m50r76q
  text: |-
    ### implement — no-change
    - evidence: 0 source files changed; the card's two criteria were checked in the description. Verified: `Scripts/swift-test.sh --filter CompactionEvalFullDataset` passed (1 test, 52.4 s against the 120 s limit, 24 of 24 seeds); `Scripts/swift-test.sh --skip IntegrationTests` passed (1008 tests in 93 suites + 75 tests in 8 suites, 0 failures, 1 known issue that a `withKnownIssue` test expects); `swift build --build-tests -Xswiftc -warnings-as-errors` completed with no compiler warning.
    - next: the card is ready for /review. Commit efd3b58 (task ^k0d30s4) already put one dearest-rate rule under the two tier limits, and `CompactionEvalTierBarTests` holds the two tiers to it.
  timestamp: 2026-08-19T19:33:14.293115+00:00
position_column: doing
position_ordinal: '8480'
title: The whole-dataset time limit rests on the mean of six samples, where the subset's now rests on the dearest — 24 samples at that rate is 140.8 minutes against a 120-minute limit
---
Found while implementing `^6ssbakk`, which re-derived `compactionEvalSubsetTimeLimitMinutes`.

## What happens

Two time limits in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` are sized from the same trail — the gated run of 2026-08-18 16:38, log `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-crit5.log` — and they use two different rules.

| constant | samples | rule | derived | states |
|---|---|---|---|---|
| `compactionEvalSubsetTimeLimitMinutes` | 7 | the DEAREST measured sample, 352.0 s | 41.1 min | 42 |
| `compactionEvalFullDatasetTimeLimitMinutes` | 24 | the MEAN of six samples, 271.0 s | 108.4 min | 120 |

The six samples that finished cost 197.4, 250.7, 260.9, 269.9, 295.1 and 352.0 seconds. The dearest is 1.78 times the cheapest, and that spread is why `^6ssbakk` sized the subset limit on the dearest: a limit at the mean is under half the measured spread away from a run it would cut short, and the subset tier has to end on its own assertion.

The same rule applied to 24 samples is 24 x 352.0 s plus the 3.5 s model load, which is 8451.5 seconds — **140.8 minutes**, over the 120 this constant states.

## Why this is its own task

`^6ssbakk` and `^xscp198` were both scoped to the SUBSET tier's own thresholds, so neither may move a whole-dataset limit. `CompactionEvalTierBarTests` therefore holds the subset tier to `compactionEvalDerivedTimeLimitMinutes(forSamples:)` and does not hold this one, and the constant's own doc says so rather than leaving the two rules silently at odds.

## What to decide

The choice is a person's, and the evidence is the spread:

1. Raise the limit to the next whole minute above 140.8 and hold this tier to `compactionEvalDerivedTimeLimitMinutes(forSamples:)` too, so one rule sizes both tiers.
2. Keep 120 and record why a tier of 24 may be sized at the mean where a tier of 7 may not — a sum of 24 draws concentrates far more tightly than a sum of 7, which is a real argument, but nothing in this repository has measured it.
3. Time the tier. It has never been run, and its own doc already asks the first run to record its real duration in place of the derivation.

## Acceptance Criteria

- [x] The two limits are sized by one stated rule, or each states why its rule differs from the other's
- [x] `CompactionEvalTierBarTests` holds the whole-dataset tier to the same derivation it holds the subset tier to, or names the measurement that releases it
#compaction #eval #real-model #test-debt