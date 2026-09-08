---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: BoundedWaitTests late-signal test fails when the test process is starved for a whole minute
---
### What

Found while reproducing task ^z5pbt5e. With the suite at background QoS beside 36 normal-priority CPU hogs (`taskpolicy -c background swift test --skip-build` and `yes > /dev/null` x36), one run took 68 s of suite time and `BoundedWaitTests/"a signal that arrives late in wall-clock terms is still observed"` failed: `BoundedWaitTests.swift:24` expectation `await BoundedWait.signalArrived(signal, named: "the late signal")` was not met. The two later runs of the same harness, at 22 s of suite time, passed all 1238 tests.

The test schedules a signal at a fixed delay inside the 5 s ceiling and asserts the wait sees it. When the process gets almost no CPU, the signal's own sleep lands after the ceiling, so the test measures the starvation and not the wait.

### What to do

- [ ] Decide whether the late-signal test must survive a starved process, or whether its premise (a signal inside the ceiling) is the thing under test and a starved run is out of scope.
- [ ] If it must survive: make the late delay a fraction of the ceiling measured from the same clock the wait reads, so both move together under starvation.
- [ ] Record the decision on the test's doc comment.

### Acceptance Criteria

- [ ] The decision is written down.
- [ ] No timeout is raised to hide the cause.