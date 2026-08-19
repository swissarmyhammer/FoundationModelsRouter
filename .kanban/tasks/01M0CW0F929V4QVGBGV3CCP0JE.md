---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
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

- [ ] The two limits are sized by one stated rule, or each states why its rule differs from the other's
- [ ] `CompactionEvalTierBarTests` holds the whole-dataset tier to the same derivation it holds the subset tier to, or names the measurement that releases it

#compaction #eval #real-model #test-debt