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
position_column: todo
position_ordinal: 8d80
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

The six totals add to 1626.0 s. The model load took 3.5 s. So about 170 s of the limit went to the unfinished seventh fold. The six measured samples averaged 271.0 s each, against about 235 s each in the run `^fz49qds` measured.

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

## Acceptance Criteria

- [ ] The gated subset ends on its own assertion, not on the time limit, with every fold applied
- [ ] The limit states the per-sample rate it was measured against, and names the applied fold as the reason for the rate
- [ ] A time-limit cancellation does not abort the process on a Metal assertion

#compaction #eval #real-model #test-debt