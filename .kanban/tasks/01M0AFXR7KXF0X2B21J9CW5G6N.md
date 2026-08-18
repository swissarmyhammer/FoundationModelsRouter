---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: The gated compaction eval subset runs its 7 samples concurrently, so every per-sample cost figure divided out of a run is wrong
---
Found by the instrumented gated run of 2026-08-18 (`^h2xxsse`). This is a measurement defect, not a product defect, and it silently corrupts how every figure on this tier gets read.

## What the trail showed

The seven samples emit their `fold started` lines one after another, every one of them at `elapsed=0.0s`:

```
[compaction-eval] sample=1/7 seed=budget-cap-tool-and-owner fold started elapsed=0.0s
[compaction-eval] sample=2/7 seed=db-port fold started elapsed=0.0s
[compaction-eval] sample=3/7 seed=encryption-algorithm fold started elapsed=0.0s
[compaction-eval] sample=4/7 seed=env-file fold started elapsed=0.0s
[compaction-eval] sample=5/7 seed=license-key-and-region fold started elapsed=0.0s
[compaction-eval] sample=6/7 seed=three-facts-long-project-brief fold started elapsed=0.0s
[compaction-eval] sample=7/7 seed=three-facts-support-escalation fold started elapsed=0.0s
```

`Evaluations` drives this tier's samples **concurrently**. All seven were in flight at once, seven generations sharing one resident MLX model.

## Why it matters

**Every per-sample cost figure derived by dividing a run by seven is wrong.** The doc comment on `compactionEvalSubsetTimeLimitMinutes` read "1644.7 seconds ... That is 235 seconds for each sample". That division assumes the samples run one after another. They do not: each sample's wall clock runs for very nearly the whole tier.

Three consequences, and each has already misled a reader:

1. **The tier has almost no headroom, and the stated margin hides it.** 1644.7 s and 1685.9 s against an 1800 s limit is 6.3% and 6.7% of room — not the comfortable "2.6 minutes over a 235-second sample" the comment implies.

2. **`0 of 7` is what a SMALL slowdown looks like, not necessarily a large one.** Seven concurrent samples finish near the end together, so one modest slowdown pushes all seven past the limit at once and the table reports a total wipeout. `^h2xxsse` reasoned from "235 s a sample" to "roughly seven times what a whole sample used to cost". That inference does not follow, and the arithmetic behind it was the divided figure.

3. **`^xscp198`'s reading is affected too.** That card records that a 7-sample tier turns one sampled refusal into a suite failure. Concurrency adds to it: the samples also contend for one model, so their individual durations are not independent of each other.

## What was already corrected

`^h2xxsse` corrected the two doc comments that carried the divided figure — `compactionEvalSubsetTimeLimitMinutes` now states that the number is a whole-run figure and must not be divided by seven, and `compactionEvalFullDatasetTimeLimitMinutes` states which of its inputs is now known wrong and in which direction (concurrency makes 24 samples cost LESS than 24 times a sample, so its derived 94 minutes still over-states and 120 is still a ceiling). No constant's VALUE was changed.

## The work

- Decide whether the tier SHOULD run its samples concurrently. Seven concurrent generations against one resident model is contention, and it is not obviously the measurement anyone intended: it makes each sample's duration depend on the other six, which is exactly what a per-sample cost figure must not do.
- If `Evaluations` exposes a concurrency limit, state it explicitly rather than inheriting the default, so the tier's shape is a decision in the code rather than a framework default nobody read.
- If it does not, record that plainly beside the limit, and derive the limit from whole-run measurements only — never from a per-sample division.
- Re-derive `compactionEvalFullDatasetTimeLimitMinutes` from a real whole-dataset run rather than from the subset, since the per-sample rate it multiplies does not exist.

## Acceptance Criteria

- [ ] The tier's sample concurrency is a stated decision in the code, not an inherited default
- [ ] No doc comment or card derives a per-sample cost by dividing a run's wall clock by its sample count
- [ ] The limits' documented basis rests on whole-run measurements only

## Related

- `^h2xxsse` — the instrumentation whose trail exposed this.
- `^azd033m` — the summarizer regression measured in the same run, whose magnitude this finding bounds the reading of.
- `^xscp198` — the same tier's intolerance of a single sampled refusal.

#compaction #eval #real-model #defect