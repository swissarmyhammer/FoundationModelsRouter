---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjr3f7ey97n02fap8ae95d
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. `compactionEvalSubsetTimeLimitMinutes` is still 30.

    Note that this card is not `^y0mhcdq`, which the audit closed as stale. The two cards name different constants and different suites.
  timestamp: 2026-08-18T23:19:18.247755+00:00
- actor: claude-code
  id: 01m0bt03zkb0mxddxbmrbd7bcb
  text: |-
    ## One figure on this card is a division — do not carry it forward

    `^9cw5g6n` criterion 2 forbids any card from deriving a per-sample cost by dividing a run's wall clock by its sample count. This card's line "against about 235 s each in the run `^fz49qds` measured" is exactly such a division: 1644.7 s over seven samples. `compactionEvalSubsetTimeLimitMinutes` no longer states it, and the comparison should not be read as a measured rate.

    The card's OWN figures are clean and stay. The trail timed each sample apart, and this card's log shows the samples ran one at a time — sample 1's four lines complete before sample 2's first line, and so on to sample 7. So 295.1, 197.4, 352.0, 260.9, 269.9 and 250.7 seconds are each one sample's own work, and their mean of 271.0 s is a measurement rather than a division.

    `compactionEvalFullDatasetTimeLimitMinutes` now rests on that 271.0 s: 24 samples is 6504 seconds, which is 108.4 minutes against the 120-minute ceiling.
  timestamp: 2026-08-19T01:26:00.947030+00:00
- actor: claude-code
  id: 01m0cv3jcxfstg130qtzzm40ag
  text: |-
    ## Research — every figure re-checked against `gated-crit5.log`

    Read the log, not the card. Each figure holds:

    - model load `took=3.5s`, stated on its own line, apart from every sample.
    - six per-sample totals, each read off that sample's own `answer returned elapsed=` line: 295.1, 197.4, 352.0, 260.9, 269.9, 250.7 s. They add to 1626.0 s. Mean 271.0 s. Spread 352.0 / 197.4 = 1.78.
    - `Suite CompactionEvaluationIntegrationTests failed after 1800.045 seconds`.
    - the seventh sample left only its `fold started` line, and `unreached: 1 of 7 seeds never ran — three-facts-support-escalation`.
    - `exited with unexpected signal code 6` stands AFTER the `counts:` and `unreached:` lines, so the report printed first.

    `compactionEvalSubsetTimeLimitMinutes` is still 30 at HEAD.

    ## The derivation this card gets

    Two figures, both from the samples the trail timed apart:

    1. What the seven really cost, as far as anything is measured. The six measured samples cost 1626.0 s. Nothing has ever timed `three-facts-support-escalation`, so it is charged the DEAREST measured sample, 352.0 s. With the 3.5 s load that is 1981.5 s — 33.0 minutes.
    2. The bound. The six samples spread by 1.78x, so a run whose seeds all land at the dear end costs more than (1). Every sample at the dearest measured cost is 7 x 352.0 + 3.5 = 2467.5 s — 41.1 minutes.

    The limit is 42 minutes: the next whole minute above the bound in (2). Margin over the bound is 0.9 minutes; margin over (1) is 9.0 minutes.

    The mean is NOT the basis. Criterion 1 asks the tier to end on its own assertion, and a limit sized on the mean (7 x 271.0 + 3.5 = 31.7 minutes) is under half the measured spread away from a run it would cut short.

    ## Two consequences

    - `CompactionEvalRepresentativeSubsetTests.subsetSizeBand` is `6...8`, and its doc says the upper bound is what the limit was measured against. That is no longer true: 8 samples at the dearest rate is 46.9 minutes, over the 42-minute limit. The band goes to `6...7`.
    - `compactionEvalFullDatasetTimeLimitMinutes` is 120, derived at 24 x the MEAN of 271.0 s. On the dearest-sample basis 24 samples is 140.8 minutes, over its own limit. That constant belongs to the whole-dataset tier, not to this subset card, so it gets its own card.
  timestamp: 2026-08-19T11:04:37.021348+00:00
- actor: claude-code
  id: 01m0cw65b8yjans5xm72e6s754
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift. `swift test` — 1107 tests in 117 suites, 0 failures, 1 pre-existing known issue (`BoundedWaitTests`). Done with `^xscp198` in one change.
    - what this card got: `compactionEvalSubsetTimeLimitMinutes` 30 -> 42, derived by `compactionEvalDerivedTimeLimitMinutes(forSamples:)` from `compactionEvalMeasuredDearestSampleSeconds` (352.0) and `compactionEvalMeasuredModelLoadSeconds` (3.5). `CompactionEvalTierBarTests` holds the constant against that derivation from both sides. The size band went `6...8` -> `6...7`.
    - open: criterion 1 needs a gated run. Criterion 3 moved to `^bkdm97c`. `^3ccp0je` carries the whole-dataset limit, which is sized on the mean where this one is now sized on the dearest.
    - next: `/review`
  timestamp: 2026-08-19T11:23:30.536458+00:00
position_column: doing
position_ordinal: '8380'
title: The gated compaction subset no longer fits its 30-minute limit now that every fold applies — 6 of 7 seeds in 1800 s
---
Measured by the sanctioned gated run of 2026-08-18 16:07 local, made for `^bgxtdk3` criterion 5. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-crit5.log`.

HEAD `3b433fb`. `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`, with `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` NOT set.

## What happens

```
✘ Test "Compaction retains pre-fold facts" recorded an issue at CompactionEvaluationTests.swift:1427:6:
  Time limit was exceeded: 1800.000 seconds
FactRetention per-sample evidence — 6 of 7 seeds measured
unreached: 1 of 7 seeds never ran — three-facts-support-escalation
```

The run measured 6 seeds and then the 30-minute limit fired while seed 7 was in its fold.

## Why the earlier measurement no longer holds

`^fz49qds` closed its first criterion on this measurement:

> the run of 2026-08-17 measured 7 of 7 subset seeds and passed on its own assertion in 1644.7 seconds, inside the 30-minute limit

That run discarded 7 folds of 7. A discarded fold costs one summarizer call and no more. `^azd033m` made the fold APPLY, and an applied fold makes the answering turn read a longer transcript. The per-sample cost went up as a result.

The trail gives the cost of each sample:

| sample | seed | fold s | answer s | total s |
|---|---|---|---|---|
| 1 | budget-cap-tool-and-owner | 241.7 | 53.4 | 295.1 |
| 2 | db-port | 136.0 | 61.4 | 197.4 |
| 3 | encryption-algorithm | 213.4 | 138.6 | 352.0 |
| 4 | env-file | 166.1 | 94.8 | 260.9 |
| 5 | license-key-and-region | 155.0 | 114.9 | 269.9 |
| 6 | three-facts-long-project-brief | 164.1 | 86.5 | 250.7 |
| 7 | three-facts-support-escalation | unfinished | — | — |

The six totals add to 1626.0 s. The model load took 3.5 s. So about 170 s of the limit went to the unfinished seventh fold. The six measured samples averaged 271.0 s each.

`^9cw5g6n` records that the tier starts its samples together. This trail shows that the generation gate holds them near to serial: the sum of the per-sample times is 1626 s of a 1800 s run, so a per-sample figure read off this trail is close to its true cost.

At 271 s each, 7 seeds need about 1900 s. The tier needs about 5 percent more time than it has.

## What must NOT be done alone

Do not raise `compactionEvalSubsetTimeLimitMinutes` and stop there. The measurement behind the limit is now wrong, and a limit put up to fit one run does not state a measurement. Three answers exist and the choice is a person's:

1. State the limit against the new measured per-sample rate of 271 s, with the applied fold named as the reason it rose.
2. Drop the subset to 6 seeds, which costs about 1626 s and fits. `^xscp198` records that a 7-seed subset held to a 0.9 mean can pass only at 7 of 7, and a 6-seed subset can pass only at 6 of 6, so this does not help the tolerance.
3. Cut the per-sample cost. The fold takes 136 s to 242 s, and the answer takes 53 s to 139 s.

## A second observation from the same trail

The process ended on signal 6 after the report printed:

```
-[_MTLCommandBuffer addCompletedHandler:]:1011: failed assertion `Completed handler provided after commit call'
... exited with unexpected signal code 6
```

The report and the counts printed first, so the run lost no measurement. The abort happens when the time limit cancels a sample that has work on the GPU.

## What landed, 2026-08-19

Answer 1 of the three above, sized on the DEAREST measured sample rather than on the mean, because the six samples spread by 1.78x and a limit at the mean sits inside that spread.

- `compactionEvalMeasuredDearestSampleSeconds` (352.0) and `compactionEvalMeasuredModelLoadSeconds` (3.5) name the two measured inputs, and `compactionEvalDerivedTimeLimitMinutes(forSamples:)` derives a tier's bound from them.
- `compactionEvalSubsetTimeLimitMinutes` is 42: the next whole minute above the derived 41.1 for seven samples. The margin is 0.9 minutes over that bound, and 9.0 minutes over the 33.0 the run really measured with the untimed seventh seed charged at the dearest sample.
- The doc names the applied fold as the reason the rate rose, and says why 1644.7 s is stale: the work changed, not the machine.
- `CompactionEvalTierBarTests` holds the limit against the derivation from BOTH sides, so a subset that outgrew the limit, and a limit that stopped stating a measurement, each fail a plain `swift test`.
- `CompactionEvalRepresentativeSubsetTests.subsetSizeBand` goes from `6...8` to `6...7`: 8 samples at the dearest rate is 46.9 minutes, over the limit.
- `compactionEvalFullDatasetTimeLimitMinutes` is left at 120, out of this card's scope, and its doc now states that it rests on the mean where this one rests on the dearest. `^3ccp0je` carries that.

## Acceptance Criteria

- [ ] The gated subset ends on its own assertion, not on the time limit, with every fold applied — OPEN. Only a gated run can show it, and a gated run is ruled out for now.
- [x] The limit states the per-sample rate it was measured against, and names the applied fold as the reason for the rate
- [ ] A time-limit cancellation does not abort the process on a Metal assertion — moved to `^bkdm97c`, which owns it. It is not a threshold question, it needs a gated run to verify, and any fix touches the MLX generation path rather than an eval constant.
#compaction #eval #real-model #test-debt