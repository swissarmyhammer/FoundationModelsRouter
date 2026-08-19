---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: A gated eval cancelled by its time limit aborts the process on a Metal assertion — signal 6 from `_MTLCommandBuffer addCompletedHandler:`
---
Split out of `^6ssbakk`, which raised `compactionEvalSubsetTimeLimitMinutes` and left this criterion of its own open.

## What happens

The gated subset run of 2026-08-18 16:38 hit its 1800-second limit while sample 7 was inside its fold. The report printed in full, and the process then died on signal 6. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-crit5.log`.

```
-[_MTLCommandBuffer addCompletedHandler:]:1011: failed assertion `Completed handler provided after commit call'
... exited with unexpected signal code 6
```

The order in the log matters and is checked: the `counts:` line and the `unreached:` line both stand ABOVE the signal line, so the run lost no measurement. The abort happens when the time limit cancels a sample that still has work on the GPU.

## Why it is its own task, and not `^6ssbakk`'s

- `^6ssbakk` and `^xscp198` are about the tier's THRESHOLDS. This is about what cancellation does to the process, and the two do not interact: once the limit fits the tier, a healthy run never cancels a sample at all.
- Any fix touches the MLX generation path rather than an eval constant. Check first whether the fault is in the vendored `mlx-swift-lm` fork; if it is, this task belongs on that fork's own board and not on this one.
- The criterion cannot be verified without provoking a time-limit cancellation, which is a gated run.

## What to find out

1. Where the completed handler is added. The assertion says a handler was attached to a command buffer that was already committed, which is a lifecycle fault rather than a cancellation policy.
2. Whether task cancellation reaches MLX at all, or whether Swift Testing's time limit simply tears the task down under a generation in flight.
3. Whether a cancelled generation can be made to drain its command buffer before the task ends.

## Acceptance Criteria

- [ ] A time-limit cancellation of a gated eval ends the test run without aborting the process
- [ ] The fault is located, and named as this repository's or as the vendored fork's

#compaction #defect #eval #real-model