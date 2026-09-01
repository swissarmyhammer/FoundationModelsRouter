---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: 'A run-plane drain test fails at random: the terminal line is missing from the drained answer'
---
## What

`RespondRunPlaneDrainTests` fails about 2 times in 100 full `swift test` runs on
a loaded machine. It never failed on an idle machine.

Two adjacent tests fail, and both fail on the same expectation:

```
✘ Test "signal 5, I am done: a run that finishes reports succeeded, and its
  terminal line reaches the model in the drained answer"
  at RespondRunPlaneDrainTests.swift:331:9:
  Expectation failed: answer.contains(OperationEventSegment.renderedLine(for: terminal))

✘ Test "signal 4, I have an error: a run whose body throws reports failed, and
  its terminal line reaches the model in the drained answer"
  at RespondRunPlaneDrainTests.swift:345:9:
  Expectation failed: answer.contains(OperationEventSegment.renderedLine(for: terminal))
```

## How it was found

The failure appeared while task ^bqj719z measured a different flaky test. The
harness runs a full `swift test` in a loop, with 64 to 96 busy processes on the
machine. The rate was 3 failures in 128 loaded full runs.

The reproduction script is in the scratchpad of that task. The shape is simple:

```sh
for i in $(seq 1 96); do ( while :; do :; done ) & done
for i in $(seq 1 30); do swift test > run_$i.log 2>&1; done
```

## What to do

- Find why the terminal line is absent from the drained answer.
- Decide whether the drain races the terminal line, or whether the test reads
  the answer before the run plane has staged it.
- Do not raise a bound, and do not add a retry.

## Note

Task ^bqj719z proved the same class of defect in `TurnCancellationTests`. There
the test polled a reading under a wall clock. The wait now ends on an event.
Check whether this test waits on a clock in the same way. #router #defect #flaky-test