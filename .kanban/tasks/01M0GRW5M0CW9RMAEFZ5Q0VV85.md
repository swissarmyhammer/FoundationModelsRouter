---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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

- [ ] The whole-dataset tier's time limit is the next whole minute above a bound derived from the whole-dataset tier's OWN measured dearest sample
- [ ] The subset tier's limit still derives from the subset's own dearest sample, and stays inside task ^k0d30s4's two-minute budget
- [ ] `CompactionEvalTierBarTests` holds both tiers against their own rates, from both sides
- [ ] The doc comment of each measured constant names the run it was measured on

#compaction #eval #real-model