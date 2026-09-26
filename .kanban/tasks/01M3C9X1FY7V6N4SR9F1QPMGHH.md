---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cwaxq2260c4qb08n5nbhd3
  text: '2026-09-25: the timeout occurred again after ^93kjn94. ^93kjn94 renamed the test to `HumanWaitGateTests.turnEndingDuringAnOutOfTurnWaitStrandsNothing` and said the re-acquire race is gone. During the test step of ^44y6ba4, one full `swift test` run failed this test with `SignalNeverArrived()`. It passed in 4 later runs (1 full run, 3 filtered runs). Thus the cause is not only the old re-acquire. This task is still valid.'
  timestamp: 2026-09-25T18:13:12.034922+00:00
- actor: claude-code
  id: 01m3dhpr7yb0p8xsg6ggavdqvt
  text: 'One more sample of the same symptom (^dpn2ytt, 2026-09-25): in the first full `swift test` after a rebuild, at load average 19 to 23, `HumanWaitGateTests.forkRacingAHumanWaitReadsTheSettledTranscript` hit the 5 s `BoundedWait` bound (`forkedDuringTheWait` false; the test took 7.8 s). The fork path in that tree has no wait at all (no turn lock, no queue). 8 later full runs and 8 processes x 100 repetitions of the suite gave 0 issues. This points at scheduler starvation of the @MainActor tests of this suite under full-suite load, not at an ordering race.'
  timestamp: 2026-09-26T00:26:39.742473+00:00
position_column: todo
position_ordinal: 8c80
title: Investigate a timeout of HumanWaitGateTests turnEndingDuringAReAcquireStrandsNoPermit under full-suite load
---
## What happened

On 2026-09-25, during the implement step of ^tv2yt7s, one full `swift test` run of the root package failed one test:

- `HumanWaitGateTests` / "a turn ending while a human wait's re-acquire is in flight strands no permit: the model family keeps generating"
- `BoundedWait.swift`: Issue recorded; `HumanWaitGateTests.swift`: Caught error: `SignalNeverArrived()`

## Measurements

- The same tree: 1 failure in 24 full runs. The suite alone: 0 failures in 8 runs.
- The tree before ^tv2yt7s (baseline): 0 failures in 12 full runs.
- The test resolves its fixture first and then drives only the session turn gates. The ^tv2yt7s change touches only the pool acquire and release paths, which end before the part of the test that timed out.

## What to do

- [ ] Reproduce with parallel repetitions of the full suite (see the memory note about the stub backend producer race for the method).
- [ ] Find which `BoundedWait.awaitSignal` timed out, and if the cause is CPU load or a real ordering race.
- [ ] Fix the cause. Do not raise the time limit to hide it.

#test-flake