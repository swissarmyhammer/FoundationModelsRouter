---
assignees:
- claude-code
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