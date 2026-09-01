---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ehva0609p3q1q5aqa9yfw7
  text: |-
    Reproduction and measurement.

    The flake does not appear on an idle machine. 30 runs of `swift test --filter TurnCancellationTests` passed. 30 more runs under 64 busy processes passed. 40 full `swift test` runs passed. That is 100 clean runs.

    The flake needs a full run AND a loaded machine. So I measured the wait instead of hunting the failure. I added a temporary probe around the `BoundedWait.spin` in `awaitCancellationReachingTheTool`. The probe reports the call site and the elapsed time. I then ran 25 full `swift test` runs under 96 busy processes.

    Result: 475 waits, and every one of them reached the condition. `reached=false` never happened. The cancellation always arrives.

    The elapsed times split cleanly by call site. 14 of the 15 sites are microseconds:
    - p50 between 2.7 and 7.7 microseconds.
    - worst single sample 3.4 milliseconds.

    One site is different. It is the direct call in `cancelledProactiveFoldReportsNoCompaction`, on the `.callerTask` route:
    - p50 = 0.12 seconds.
    - p90 = 2.06 seconds.
    - max = 2.07 seconds.
    - 7 of 25 samples above 1 second.

    Every sample above 1 second in the whole data set comes from that one site.

    `BoundedWait.ceilingNanoseconds` is 5 seconds. The tail is already 2 seconds. The margin is a factor of 2.4. A machine more loaded than this one crosses the ceiling, and the test records the issue at the reported line. This matches the card exactly: the same test, the same argument.

    So the cancellation reaches the tool. The wait gives up too early. This is a test defect of the kind commit dfb1da8 named: the test waits on the clock, not on the event.
  timestamp: 2026-09-01T13:16:59.782675+00:00
- actor: claude-code
  id: 01m1ekx6gamyppbptcmgsdhpc2
  text: |-
    Cause found, and it is not what the first measurement suggested.

    I replaced the wall-clock spin with an `AwaitedEvent` the tool signals. I then measured the new wait at the same call site. It still took about 2 seconds. So the delay is the propagation itself, not the polling.

    Three measurements isolate the cause:
    - The test run alone: 50 to 90 microseconds.
    - The full suite with `--no-parallel`: 10 to 20 microseconds.
    - The full suite in parallel: about 1.9 seconds in half of the runs, and 10 to 20 milliseconds in the other half.

    CPU load is not the cause either. An idle machine shows the same 1.9 second plateau in a full parallel run.

    The cause is main-actor contention. `cancelCurrentTurn()` cancels the model call directly, so the stop lands in microseconds. The `.callerTask` route cancels the stream consumer instead. That consumer must run again before its `next()` terminates the stream. The termination handler then cancels the turn, and only then does the stop travel to the tool. The consumer is `@MainActor`, because the test that made it is. So it waits for the one main actor that every `@MainActor` test in the run shares.

    The old wait gave up after 5 seconds. The crossing already took 2 seconds here. A busier machine than this one crosses 5 seconds, and the test records the issue.

    So the defect is in the test, not the product. Router delivers the cancellation correctly. `Task.cancel()` promises only that a cancellation is observed at the next cancellation point, and on this route that point is a main-actor hop. A wall clock over it measures the run.

    The sibling spin in the same test was measured too. `BoundedWait.spin` on `recorder.events.count` gave p50 2.4 ms, p90 8.8 ms and max 41 ms, against the same 5 second ceiling. That is a margin of about 100 times, so it is not a flake risk and I left it alone.
  timestamp: 2026-09-01T13:52:58.890334+00:00
- actor: claude-code
  id: 01m1eky4d7thbjda1pp0wp8ztc
  text: |-
    ### implement — changed
    - files: Tests/FoundationModelsRouterTests/TurnCancellationTests.swift
    - the tool now signals an `AwaitedEvent` when it observes the cancellation, and returns it. `suspendInsideCancellationAwareTool` returns `AwaitedEvent` in place of the semaphore.
    - `awaitCancelledUnwind` and `awaitCancellationReachingTheTool` become one throwing helper. It waits on the event, then asserts the `CancellationError`.
    - the suite carries `.timeLimit(.minutes(1))`. That limit ends a wait a real regression never resolves, so a fault fails the test instead of hanging the run.
    - 14 call sites renamed `suspended` to `sawCancellation`.
    - nothing was skipped, retried, or weakened. The old give-up path recorded an issue and carried on. The new path throws `EventNeverArrived`, which is a harder failure.
    - before: at that call site, p50 0.12 s, p90 2.06 s, max 2.07 s, against a 5 second ceiling. 7 of 25 samples above 1 second.
    - after: 55 full `swift test` runs under 96 busy processes, and 20 runs of `swift test --filter TurnCancellationTests`. Zero cancellation failures.
    - `swift test`: 1159 tests in 128 suites and 83 tests in 10 suites, exit 0, 2 known issues. This matches the baseline.
    - one unrelated flaky test appeared 3 times in 128 loaded runs: `RespondRunPlaneDrainTests`. It failed before this change as well. Raised as ^91m8p4k.
    - next: /review
  timestamp: 2026-09-01T13:53:29.511419+00:00
- actor: claude-code
  id: 01m1em1nfy5aw5vt28bnws7tqm
  text: |-
    ### commit — changed
    - evidence: 2a3e0c0 fix(tests): wait on an event, not a clock, for turn cancellation
    - staged: Tests/FoundationModelsRouterTests/TurnCancellationTests.swift, .kanban/tasks/01M1D3Q3TDWWT3QTD42BQJ719Z.jsonl, .kanban/tasks/01M1D3Q3TDWWT3QTD42BQJ719Z.md, .kanban/tasks/01M1EKWSSNRDNE0MCCC91M8P4K.jsonl, .kanban/tasks/01M1EKWSSNRDNE0MCCC91M8P4K.md
    - next: none, local commit only, not pushed
  timestamp: 2026-09-01T13:55:25.310456+00:00
- actor: claude-code
  id: 01m1emrejmxc1w6pgvy5k7rth3
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD`. 7 validators ran. 0 findings, 0 confirmed, 0 refuted, 0 failed.
    - scope: commit 2a3e0c0 only. `git diff HEAD~1..HEAD -- Sources` gives 0 lines. The change touches tests only.
    - crux, the new failure mode is clean: `AwaitedEvent.wait()` uses `withTaskCancellationHandler`. A cancel resumes the waiter and throws `EventNeverArrived`. `AwaitedEventTests.aCancelledWaitEnds` proves this. So a cancellation that never reaches the tool fails the test. It does not hang the run.
    - the `.timeLimit(.minutes(1))` is on the `@Suite` declaration. Swift Testing applies a suite trait to each test in the suite.
    - no test was skipped, retried, weakened, or given a longer budget. The suite holds 23 `@Test` before and after. The diff adds no `.disabled`, no `withKnownIssue`, no retry, and no sleep.
    - the new path is stricter. The old path recorded an issue and continued. The new path throws out of the test.
    - the signal follows the observer write: `await observer.noteToolSawCancellation()` runs before `sawCancellation.signal()`. A resumed test always reads fresh state.
    - the sibling `BoundedWait.spin` on `recorder.events.count` is unchanged, so it is outside the scope of a diff review. Leaving it is defensible. A hard `#expect` follows it, so a give-up fails cleanly. The measured margin is about 100 times.
    - doc claims checked and true: the microsecond and two-second measurements; "thirty times the slowest crossing" (60 s over 2.07 s); and `AsyncSemaphore.wait()` ignores cancellation, because it is non-throwing and holds no cancellation handler.
    - my own runs: 31 `swift test` invocations, 0 failures. 1 baseline, 20 filtered on `TurnCancellationTests`, 10 full. Full run reports 1159 tests in 128 suites and 83 tests in 10 suites, with 2 known issues.
    - next: none. The task moves to done.
  timestamp: 2026-09-01T14:07:51.892597+00:00
- actor: claude-code
  id: 01m1emsjshbhs8tm2a0vh7mnpt
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 test file. No source file changed.
    - test: green — swift test, 1159 tests in 128 suites + 83 tests in 10 suites, exit 0
    - commit: 2a3e0c0
    - review: clean — 0 findings, 7 validators, 0 failed. Task moved to done.

    The measurement is the valuable part of this card. The failure never appeared
    in 100 runs of narrower shapes, so the wait itself was measured instead of
    guessed at. 475 waits over 25 full runs under 96 busy processes: 14 of the 15
    call sites take microseconds, and one takes p90 2.06 seconds against a
    5-second ceiling. Every sample above one second in the whole set is that one
    site.

    The cause is structural and not load. `cancelCurrentTurn()` cancels the model
    call directly. The `.callerTask` route cancels the stream consumer, and the
    stop reaches the tool only when that consumer runs again on the shared main
    actor. Run alone the same wait takes 50 microseconds.

    The reviewer checked the thing that mattered: the new wait fails cleanly rather
    than hanging. `AwaitedEvent.wait()` is cancellation-aware, the suite carries
    `.timeLimit(.minutes(1))`, and `AwaitedEventTests.aCancelledWaitEnds` already
    proves the throw. The new path is stricter than the old one, which recorded an
    issue and continued.

    Verification: 55 full loaded runs plus 20 filtered runs by the implementer, and
    31 more runs by the reviewer. Zero cancellation failures.

    Two unrelated flakes were found while measuring and carded rather than fixed
    here: `^91m8p4k` (RespondRunPlaneDrainTests, 3 failures in 128 loaded runs).
  timestamp: 2026-09-01T14:08:28.977029+00:00
position_column: done
position_ordinal: ffffb380
title: 'A turn-cancellation test fails at random: the cancellation does not reach the tool in time'
---
## What

`swift test` failed one time in three runs on 2026-08-31. The other two runs
passed. Nothing in the working tree touched Swift code. Only `README.md`
changed. The failure is therefore a flake in the test itself.

The failing test:

```
✘ Test "a turn cancelled inside its own proactive fold reports no compaction, because none happened"
  recorded an issue with 1 argument route → the caller's own Task
  at TurnCancellationTests.swift:950:25: Issue recorded
✘ Test run with 1136 tests in 126 suites failed after 7.511 seconds with 3 issues (including 2 known issues).
```

`Tests/FoundationModelsRouterTests/TurnCancellationTests.swift` line 950 holds
this call, inside `awaitCancellationReachingTheTool(_:observer:suspended:)`:

```swift
Issue.record("cancellation never reached the tool call running inside the model call")
```

The helper first calls `BoundedWait.spin(until: { await observer.toolSawCancellation })`.
The spin gave up before the tool observed the cancellation. The bound is too
short for a loaded machine, or the test misses a deterministic signal.

## What to do

- [x] Find why the tool does not see the cancellation inside the bound.
- [x] Make the wait deterministic, or state a bound the machine can always meet.
- [x] Do not raise the bound alone if a real ordering defect causes the miss.

## Acceptance Criteria
- [x] The cause of the missed cancellation is stated.
- [x] The test passes 20 times in a row.
- [x] No other test in the suite becomes slower.

## Tests
- [x] Run the suite 20 times: `for i in $(seq 20); do swift test --filter TurnCancellationTests || break; done`.

## The cause

The cancellation always reaches the tool. It just takes about 2 seconds on one
route, in a full parallel run. The old wait gave up after 5 seconds.

`cancelCurrentTurn()` cancels the model call directly, so the stop lands in
microseconds. The `.callerTask` route cancels the stream consumer instead. That
consumer must run again before its `next()` terminates the stream. Only then
does the termination handler cancel the turn and pass the stop on. The consumer
is `@MainActor`, so it waits for the one main actor every `@MainActor` test in
the run shares.

Measured at that call site:
- run alone: 50 to 90 microseconds;
- full suite, `--no-parallel`: 10 to 20 microseconds;
- full suite, parallel: about 1.9 seconds in half the runs.

The defect is therefore in the test, not in Router.

## The fix

The tool signals an `AwaitedEvent` when it observes the cancellation. The test
waits on that event. `awaitCancelledUnwind` and `awaitCancellationReachingTheTool`
become one throwing helper, and the suite carries `.timeLimit(.minutes(1))` to
end a wait a real regression never resolves.

## Note

Found while working task ^2ennye2 (a README correction). #router #defect #flaky-test