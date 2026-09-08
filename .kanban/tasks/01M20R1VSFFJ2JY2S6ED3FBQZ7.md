---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20t70pk92cx2w1eqfkxs7gw
  text: |-
    ### Research

    Files read: `Tests/FoundationModelsRouterTests/BoundedWaitTests.swift` and `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`. `lateSignalDelayNanoseconds` has no user outside the test file. `BoundedWait` itself is not changed by this task.

    How the failure happens:

    - `BoundedWait.spin(until:)` sets `deadline = ContinuousClock.now + 5 s` at the start of the wait. In each loop turn it reads the condition first, then the deadline.
    - The late-signal test starts a second task that does `Task.sleep(400 ms)` and then `signal.signal()`. The wait reads `availablePermits > 0`.
    - When the process gets no CPU, the wall clock does not stop. The sleep expires at T+400 ms, but the task that must run after the sleep only runs when the scheduler gives it a thread. When the waiter gets a thread after T+5 s, and the signaller has not run yet, the waiter reads `permits == 0`, then reads `now >= deadline`, and returns `false`. The wait did what its contract says. The premise of the test (a signal inside the ceiling) was false in that run.

    Why the "same clock" sleep alone does not help:

    - `Task.sleep(nanoseconds:)` and `ContinuousClock` both advance in wall time during CPU starvation. A sleep on `ContinuousClock` still needs the signaller task to get a thread before T+5 s. No clock choice gives a second task a thread. So a signaller that sleeps cannot be made to survive starvation.

    What can survive:

    - If the late condition is read on the same clock, inside the waiter's own condition closure (`ContinuousClock.now >= start + delay`), no second task is needed. The waiter reads the condition before it reads the deadline in every loop turn, so any turn that runs after T+delay observes the condition, no matter how late the turn runs. The premise then holds by construction on the clock the wait reads.

    Rules loaded from `dump validators` (prompt rules for a Swift test file, and the Swift tool-rule sections for magic numbers, idioms, and missing docs). Points that constrain the edit: a literal in an expression is a magic number unless a declaration names it; no `guard` in a test; an unused declaration is dead code.
  timestamp: 2026-09-08T15:29:31.859425+00:00
- actor: claude-code
  id: 01m20tjrxk465hhz6dypkhjdyb
  text: |-
    ### Implementation and evidence

    Harness: `scratchpad/starve.sh` runs the one test under a pty, waits for the `started` line, then sends `SIGSTOP` to the `FoundationModelsRouterTests.xctest` runner for 6 s (longer than the 5 s ceiling), then `SIGCONT`. No `yes` hogs were used, so there is nothing to kill; `pgrep -l yes` finds no process.

    Results, each with a 6 s stop inside the test:

    - Old test (signaller task with `Task.sleep(nanoseconds:)`): failed 3 of 3, at `BoundedWaitTests.swift:24`, with the same issue text as the card.
    - Card option 2 as a sleep (`Task.sleep(for:clock: .continuous)` in the signaller task): failed 2 of 2. This shows the clock is not the cause. The signaller task needs a thread before the deadline, and no clock gives it one.
    - New test (the late change is `ContinuousClock.now >= landsAt` inside the wait's own condition, `landsAt = start + ceiling / 10`): passed 3 of 3, each reported after about 6.06 s, so the stop landed inside the test.

    Mutation check (RED): with `spin(until:)` changed to give up after its yields (a hop count), `swift test --skip-build --filter 'FoundationModelsRouterTests.BoundedWaitTests'` reports `Test run with 2 tests in 1 suite failed`; the late-change test fails at `BoundedWaitTests.swift:40`. `BoundedWait.swift` was then restored with `git checkout`, and the filtered run reports `Test run with 2 tests in 1 suite passed`.

    Changes: only `Tests/FoundationModelsRouterTests/BoundedWaitTests.swift`. The test now calls `BoundedWait.conditionReached` directly; `signalArrived` is a one-line reading over it and is exercised by the other suites. The constants are `lateChangeCeilingDivisor = 10` and `lateChangeDelay = .nanoseconds(BoundedWait.ceilingNanoseconds / lateChangeCeilingDivisor)`. The second test compares its elapsed time with `lateChangeDelay`. The ceiling is unchanged.

    Dead end recorded: a sleep on `ContinuousClock` in a second task. Do not try it again.
  timestamp: 2026-09-08T15:35:57.107447+00:00
- actor: claude-code
  id: 01m20tknj9xnnjexdrv6b00m1z
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/BoundedWaitTests.swift. `swift test --skip-build --filter 'FoundationModelsRouterTests.BoundedWaitTests'`: Test run with 2 tests in 1 suite passed. Full `swift test --skip-build`: Test run with 1238 tests in 134 suites passed with 2 known issues; Test run with 83 tests in 10 suites passed. Zero failures, zero warnings. Starvation harness (SIGSTOP 6 s inside the test): old test failed 3 of 3, new test passed 3 of 3. No hog process was started; `pgrep -l yes` finds none.
    - next: /review
  timestamp: 2026-09-08T15:36:26.441264+00:00
- actor: claude-code
  id: 01m20tvv7jc56cmz2zbhh0sc9j
  text: |-
    ### test — green
    - evidence: `swift test --parallel` — run 1: FoundationModelsRouterTests process trapped with signal 5 (SIGTRAP), matching known issue ^9smkhk8 (RoutedSessionActor.recordTranscriptDelta trap during a failed streamResponse turn); rerun per the rule. Run 2: clean — FoundationModelsRouterTests: 1238 passed, 0 failed, 0 skipped, 2 known issues (both deliberate `withKnownIssue` assertions: RealModelHarness.swift:72 embedding-slot check, BoundedWait.swift:114 never-holds-condition check); FoundationModelsRouterEvals: 83 passed, 0 failed, 0 skipped, 10 suites. 0 warnings from the changed file (Tests/FoundationModelsRouterTests/BoundedWaitTests.swift); only pre-existing C++17-extension warnings from the vendored mlx-swift dependency, unrelated to this change.
    - next: none
  timestamp: 2026-09-08T15:40:54.386072+00:00
position_column: doing
position_ordinal: '80'
title: BoundedWaitTests late-signal test fails when the test process is starved for a whole minute
---
### What

Found while reproducing task ^z5pbt5e. With the suite at background QoS beside 36 normal-priority CPU hogs (`taskpolicy -c background swift test --skip-build` and `yes > /dev/null` x36), one run took 68 s of suite time and `BoundedWaitTests/"a signal that arrives late in wall-clock terms is still observed"` failed: `BoundedWaitTests.swift:24` expectation `await BoundedWait.signalArrived(signal, named: "the late signal")` was not met. The two later runs of the same harness, at 22 s of suite time, passed all 1238 tests.

The test schedules a signal at a fixed delay inside the 5 s ceiling and asserts the wait sees it. When the process gets almost no CPU, the signal's own sleep lands after the ceiling, so the test measures the starvation and not the wait.

### What to do

- [x] Decide whether the late-signal test must survive a starved process, or whether its premise (a signal inside the ceiling) is the thing under test and a starved run is out of scope.
- [x] If it must survive: make the late delay a fraction of the ceiling measured from the same clock the wait reads, so both move together under starvation.
- [x] Record the decision on the test's doc comment.

### Decision

The test must survive a starved process. The suite exists to prove the wait is proof against load, so the premise of the test cannot rest on the scheduler. The late change is now a reading of `ContinuousClock` inside the wait's own condition, at `BoundedWait.ceilingNanoseconds / 10`. A signaller task that sleeps, on any clock, cannot survive: the sleep ends on time, but the task gets no thread before the deadline. The doc comment on `aLateChangeIsStillObserved` records this. `BoundedWait` and its ceiling are not changed.

### Acceptance Criteria

- [x] The decision is written down.
- [x] No timeout is raised to hide the cause.