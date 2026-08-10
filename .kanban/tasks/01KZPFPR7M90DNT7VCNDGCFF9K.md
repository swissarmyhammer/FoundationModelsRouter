---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
title: '[Router] BoundedWait''s yield-count bound makes HumanWaitGateTests fail under machine load'
---
## What happened

A full `swift test` run failed with 6 issues in 3 tests. All 3 tests are in the suite "Human waits release the per-model generation gate, never the per-session turn lock" in `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift`:

- "awaitingUser with no turn in flight runs the body and releases nothing" — `HumanWaitGateTests.swift:904`, error `RunNeverFinished()`.
- "a turn ending while a human wait's re-acquire is in flight strands no permit: the model family keeps generating" — `HumanWaitGateTests.swift:817`, error `SignalNeverArrived()`.
- "a human wait overlapping a turn it is not part of leaves the gate at exactly one permit" — `HumanWaitGateTests.swift:738`, error `RunNeverFinished()`.

Each of the 6 issues comes from the same line: `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift:70`.

## Why it is a defect, not only bad luck

`BoundedWait.spin(until:)` gives a condition `yieldLimit` cooperative yields. `yieldLimit` is 100000 hops. The bound counts scheduler hops. It does not measure wall-clock time.

The doc comment on `yieldLimit` makes this claim: a state change that a test puts behind some task suspensions "always lands" inside the bound. That claim is not true when the machine has a heavy load. The task that must cause the state change can get very few time slices. The task that waits can then use all 100000 yields before the other task runs sufficiently. The wait then gives up, although the code is correct.

Thus the bound is a function of the load on the machine. A test that is correct can fail. This is the type of failure that makes a suite unreliable.

## Evidence

- The failure came in a full `swift test` run directly after a `periphery scan` and a `swift build --build-tests`. The machine had a heavy load.
- The immediately previous full run of the same code was green.
- The immediately subsequent full run of the same code was green: 781 tests in 74 suites, 24 in 9, 24 in 5.
- `swift test --filter HumanWaitGate` alone gives 9 tests in 1 suite, and the suite completes in 0.077 seconds. In the failed run the same 3 tests each took 3.0 to 3.7 seconds before they gave up.

The difference between 0.077 seconds and 3.7 seconds shows the starvation. The tests do not wait for a condition that is false. They wait for a condition that arrives too late for a bound that counts hops.

## What to do

Make the bound independent of the load on the machine. Do not simply increase `yieldLimit`: a larger count of hops still fails at a sufficiently heavy load, and it also makes each true failure slower.

Examine these options:

- Give the bound a wall-clock deadline as well as the hop count. End the wait when the condition holds. Report a fault only after the deadline passes.
- Wait on an event instead of a poll, if the observed value permits it.

Keep the properties that the existing doc comment gives as the reason for this helper:

- The wait must always end. `AsyncSemaphore.wait()` ignores cancellation, thus a bare wait can stop the full `swift test` run.
- A fault must report through `Issue.record` and name what did not happen.
- Do not collapse the two steps of `awaitSignal`. The reading of `availablePermits` must stay before the `wait()`.

## Acceptance Criteria

- [ ] The bound of `BoundedWait` does not fail because of the load on the machine.
- [ ] The 3 named tests pass when the machine has a heavy load. Put a load on the machine, then run the suite, to make the check.
- [ ] A condition that is truly false still ends the wait, and still records an issue that names it.
- [ ] `swift test` green.

## Notes

Found during work on `^vhjhaey`. That card changes comment lines only, thus it does not cause this failure. `git diff -- Sources` was 0 bytes for the full period.