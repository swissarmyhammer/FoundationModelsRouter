---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: The gated compaction continuity eval has the same one-bit defect — it prints nothing until it ends
---
Found while instrumenting the fact-retention tier for `^h2xxsse`.

## What happens

`CompactionContinuityEvaluationTests` is the second gated eval tier in `FoundationModelsRouterEvals`. It runs under `gatedEvalSuiteTimeLimitMinutes` (20 minutes), it drives a real `RoutedSession` per sample through `CompactionContinuityEvalRealSubjectRunner.run(steps:finalInstruction:prompt:budget:)`, and it writes nothing at all while it runs.

That is exactly the shape `^h2xxsse` names on the fact-retention tier: a measurement that costs tens of minutes and, when its time limit cuts it short, reports one bit — "not finished". A run of this tier that hits its 20-minute limit cannot say whether the model load, one step of one sample, or the final instruction spent the time.

## What `^h2xxsse` did, and why it stopped at the boundary

`^h2xxsse` added `CompactionEvalProgressLog` (`Tests/FoundationModelsRouterEvals/CompactionEvalProgressLog.swift`) and wired it into `CompactionEvalRealSubjectRunner`:

- the model load timed and stated on its own two lines, so it is never charged to the first sample,
- one line for each sample when its fold starts, when the fold returns, when the answering turn starts, and when it returns, each with elapsed seconds.

It stopped at the fact-retention runner deliberately. The continuity runner is a different type with a different `run` signature, it carries no `[CompactionEvalSeed]` to number its samples against, and its samples are a LIST OF STEPS rather than one fold plus one answering turn — so its step vocabulary is not `fold`/`answer` and its label is not `sample=n/total seed=id`. Instrumenting it is real work rather than one line of that change, and half-doing it would have left two gated tiers with two different trails.

## The work

- Decide the continuity tier's own step vocabulary. `CompactionEvalProgressStep` is a `String`-raw-valued enum for exactly this reason — extend it, or give the continuity tier its own, but keep `CompactionEvalProgressLog.linePrefix`, `startedMarker`, `returnedMarker` and `makeSecondsText(_:)` shared so one `grep` reads both tiers.
- Time `CompactionContinuityEvalRealSubjectRunner.container()`'s model load on its own lines, exactly as the fact-retention runner now does. That runner's `container()` is a near-copy of the other one and is the obvious first site.
- Emit one line for each step the sample drives, and one for the final instruction, each naming the sample and stating its own seconds.
- Cover the rendering hermetically, beside `CompactionEvalProgressLogTests`.

## Acceptance Criteria

- [ ] A continuity run states its model load time apart from its sample time
- [ ] A continuity run prints one line for each sample while it runs, so a run that hits its limit names the sample it stopped in
- [ ] Each sample states the time of each step it drove
- [ ] Both gated tiers' trails share one line prefix and one seconds rendering, so one `grep` reads either

## Related

- `^h2xxsse` — the same defect on the fact-retention tier, and the `CompactionEvalProgressLog` this card extends. #compaction #eval #real-model #defect