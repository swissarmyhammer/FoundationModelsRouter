---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqz3nh7cgwp3d6f8pmabd
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. 7 seeds, a floor of 0.9, and provider sampling that is not pinned — all unchanged.

    Today's gated run confirms that the tier has no tolerance: 4 of 6 measured seeds carried the fact, and the mean was 0.333.
  timestamp: 2026-08-18T23:19:13.781974+00:00
position_column: todo
position_ordinal: '8380'
title: The 7-seed gated subset can only pass FactRetention at 7 of 7 — 6 of 7 is 0.857, under the 0.9 bar, so the tier has no tolerance for model sampling
---
Found by the gated subset run of 2026-08-17 21:42 while measuring `^fm5ddk9`.

## What happens

`compactionEvalFactRetentionFloor` is `0.9`, and `compactionEvalRepresentativeSeeds` holds 7 seeds. `FactRetention` scores one bit per sample, so the only means the tier can produce are `k/7`:

| retained | mean |
|---|---|
| 7 | 1.000 |
| 6 | 0.857 |
| 5 | 0.714 |

`6/7 = 0.857` is under `0.9`. So the subset tier passes at 7 of 7 and at no other count: the stated bar of "at least 0.9" is, on this tier, "every seed, every run".

## The run that showed it

Two runs of the same tier, against code whose fold behaviour is identical:

- 2026-08-17 20:xx (recorded on `^fz49qds`): 7 of 7 retained, mean 1.0, PASSED in 1644.7 s.
- 2026-08-17 21:42 (recorded on `^fm5ddk9`): 6 of 7 retained, mean 0.857, FAILED in 1675.3 s.

The one seed that moved is `env-file`. It answered `I don't have access to that project's files or secrets, so I can't confirm where its API key is stored.` where the earlier run had answered with the key phrase. Nothing about the fold changed between the two runs — every sample of both runs discarded its fold and answered from the original transcript.

`^fz49qds` already recorded the cause in its own words: this runner "leaves the provider's own sampling in place rather than pinning `.greedy`, so answer lengths move between runs of identical code". What it did not record is that a 7-sample tier turns any single sampled refusal into a suite failure.

## Why this is its own task

It is independent of `^fm5ddk9`. Once folds are applied and `FactRetention` measures a summary rather than the original turns, the tier still passes only at 7 of 7 — a bar with no tolerance against a sampling model is a flaky gate whatever it is measuring.

Three answers exist and the choice is a person's:

1. Pin the runner's sampling to `.greedy` so identical code gives identical answers, and keep the bar. That makes the tier deterministic and makes a red run mean something.
2. Widen the subset, so a single sampled refusal is not the whole difference. Every added seed costs about 235 s of wall clock, and `^fz49qds` sized the tier against a 30-minute limit that the last run used 27.9 minutes of. There is no room without raising the limit.
3. State the bar in samples rather than in a mean, so the tier says what it really requires.

Prefer 1: it removes the variance rather than budgeting for it, and it costs no wall clock.

## Acceptance Criteria

- [ ] Two gated subset runs of identical code produce identical verdicts, or the tier's bar states the tolerance it really has
- [ ] The relationship between the seed count and the floor is stated where the floor is declared, so a subset that cannot express the bar cannot be chosen silently #compaction #eval #real-model