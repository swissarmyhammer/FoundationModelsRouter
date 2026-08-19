---
assignees:
- claude-code
position_column: todo
position_ordinal: '9280'
title: Two gated runs of the same eval code drove the samples two different ways, so the tier's dispatch shape is unmeasured
---
Found while correcting `^9cw5g6n`. `^9cw5g6n` states that `Evaluations` drives this tier's samples concurrently. The raw trails say that is true of one run and false of another, and no code changed between them.

## The two trails

Both logs sit in this session's scratchpad, and both ran `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` over the same seven subset seeds.

`gated-run-3.log`, 2026-08-18 07:34 (task `^h2xxsse`, right after commit `523689b`):

```
sample=1/7 ... fold started elapsed=0.0s
sample=2/7 ... fold started elapsed=0.0s
sample=3/7 ... fold started elapsed=0.0s
sample=4/7 ... fold started elapsed=0.0s
sample=5/7 ... fold started elapsed=0.0s
sample=6/7 ... fold started elapsed=0.0s
✘ Time limit was exceeded: 1800.000 seconds
sample=7/7 ... fold started elapsed=0.0s
```

Six samples in flight together. No fold returned in 1800 s. `0 of 7 seeds measured`.

`gated-crit5.log`, 2026-08-18 16:38 (task `^6ssbakk`, commit `3b433fb`):

```
sample=1/7 ... fold started elapsed=0.0s
sample=1/7 ... fold returned elapsed=241.7s took=241.7s
sample=1/7 ... answer started elapsed=241.7s
sample=1/7 ... answer returned elapsed=295.1s took=53.4s
sample=2/7 ... fold started elapsed=0.0s
...
```

Strictly one sample at a time, samples 1 through 7 in order, every sample's four lines complete before the next sample's first line. `6 of 7 seeds measured`.

`git diff 523689b 3b433fb -- Tests/FoundationModelsRouterEvals Sources/` touches `Summarization.swift`, `UTF8Budget.swift`, `ToolOutputCapping.swift` and `CompactionEvaluationTests.swift`. It touches NOTHING that dispatches a sample: `CompactionEvalRealSubjectRunner`, `CompactionEvaluation` and the `.evaluates(...)` trait are all identical across the two runs.

## Why this matters

Both time limits rest on how the tier spends its time, and the shape decides that. Six samples in flight cost the run all seven samples when the limit fires; one sample at a time costs the run only the tail. `^h2xxsse` reported `0 of 7` and `^6ssbakk` reported `6 of 7` for the same seven seeds, and the difference is the shape rather than the model.

A per-sample cost read off a trail is only clean when the samples ran one at a time. `^6ssbakk`'s figures are clean by that test. `^h2xxsse`'s would have carried each sample's wait on the other five.

## One correction this card carries

`elapsed=0.0s` on a `fold started` line proves NOTHING about concurrency. `CompactionEvalRealSubjectRunner.run(entries:prompt:budget:question:)` passes `elapsedSeconds: 0` as a literal, so the field is the sample's own elapsed time and it is zero at every fold start. `^9cw5g6n`'s description reads that field as evidence. The real evidence is the ORDER of the lines: seven `fold started` lines with no `fold returned` line between them.

## What to do

- Measure the dispatch shape rather than reading it off a trail. A hermetic `Evaluation` — a small dataset, a `subject(from:)` that records how many samples are in flight, and no `ModelJudgeEvaluator` — drives `Evaluation.run(info:)` with no model at all and states the answer.
- Decide what the tier should do with the answer. `Evaluation.run(info:)` and `.evaluates(_:info:recordTranscripts:)` take no concurrency limit, so the tier cannot ask for one. Serialising the samples inside `CompactionEvalRealSubjectRunner` is the seam that is available.
- Correct `^9cw5g6n`'s description, which states the concurrent shape as a settled fact.

## Acceptance Criteria

- [ ] A hermetic test states how many samples `Evaluations` drives at once, and it needs no model
- [ ] The tier's dispatch shape is a decision the code holds, or the code records that the shape is the framework's and states what a reader must not conclude from it
- [ ] No document reads `elapsed=0.0s` as evidence of concurrency

## Related

- `^9cw5g6n` — the card whose premise this bounds.
- `^6ssbakk` — the serial trail, and the per-sample figures both limits now rest on.
- `^h2xxsse` — the concurrent trail, and the instrumentation that made both legible.

#compaction #eval #real-model #test-debt