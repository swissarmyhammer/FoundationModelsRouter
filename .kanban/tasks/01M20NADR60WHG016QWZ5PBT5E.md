---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20q306t4kdk1965f85b3mh9
  text: |-
    Picked up. Research result:

    Delivery chain, read from the code:
    - `ToolRun.execute` runs the body, settles the funnel, then awaits `sink.post(invocation: closeRecord)` and `sink.postToolCallReport(...)`. The sink is the `SessionOutbox`, which awaits `invocationObserver.deliver(...)`. The observer is the session actor, whose `deliverLive` calls `emitSessionScopedEvent`, which does `continuation.yield` on each `streamSessionEvents()` subscription. Every hop is an awaited actor call.
    - The mailbox settles the run from `settling: Task { await work.value.terminal }`, and `work` completes only when `execute` returns. So when `mailbox.wait` returns `.settled`, the close record and the report are already in the stream's unbounded buffer.
    - The test subscribes before it opens the gate, so the report cannot be lost by a late subscription.

    The one nondeterministic step is the hop from the stream into `SessionEventLog`. The test is `@MainActor`, so its `collecting` Task inherits the main actor and competes with every other `@MainActor` test body in the parallel run. `BoundedWait.conditionReached` gives that hop 5 s of wall clock. In the failing run other tests reported durations near 7.8 s, so the main-actor queue was more than 5 s deep and the bound expired while the report sat in the buffer.

    Reproduction attempts so far: one plain full run and three full runs under 24 `yes` CPU hogs, all green (1238 tests each). `yes` does not load the test process: the run stayed near 5 s. In those runs the test took 3.4 to 3.9 s although it takes 14 ms alone, which shows it spends most of its time waiting for main-actor time. Next: run several copies of the built test binary at the same time to get the load of the failing run.

    Plan for the fix: after `mailbox.wait` returns `.settled`, close the session (which finishes every session-event subscription first) and drain the stream with the existing `collect(_:)` helper. No wall clock at all. A lost report then fails `expectOneReportFollowsClose` with a clear message instead of a timeout.
  timestamp: 2026-09-08T14:34:54.554026+00:00
- actor: claude-code
  id: 01m20qnvkxp43sc2v68a8b4an4
  text: |-
    Reproduced the timeout under load.

    What did not reproduce it:
    - 24 `yes` CPU hogs beside a normal `swift test`: 3 runs green, suite time stayed near 5 s.
    - 6 concurrent `swift test --skip-build` copies, 3 rounds: all 18 runs green. The test rose to 4.83 s (from 14 ms alone) but stayed inside the bound. The suite's wall time is pinned near 5 s by the BoundedWait self-test, so extra processes do not starve one test process much on an 18-core machine.

    What reproduced it:
    - The suite at background QoS beside 36 normal-priority hogs: `taskpolicy -c background swift test --skip-build` with `yes > /dev/null` x36. Three runs, three failures of this test, each with the card's exact shape: `BoundedWait.swift:114` records `the report on streamSessionEvents() was never observed inside the bound`, then `ToolInvocationLivenessTests.swift:553` fails `events.firstIndex { $0.carriedReport != nil } -> nil`.
    - Run 1 (76 s suite time) also failed other tests (41 issues). Runs 2 and 3 (40 s and 21 s suite time) failed only this test: 5 issues = this test's 3 + the 2 known issues. So this test is the most load-sensitive test of the 1238.

    Answer to the card's question: the bound is what fails, not the delivery. The report is in the stream buffer before the mailbox settles; the 5 s wall clock runs while the main-actor `collecting` task waits its turn behind the other `@MainActor` test bodies. The scripts are in the session scratchpad (`load-runs.sh`, `heavy-runs.sh`, `throttled-runs.sh`); the throttled one is the harness to prove the fix.
  timestamp: 2026-09-08T14:45:12.445029+00:00
- actor: claude-code
  id: 01m20r306vv9j7mvr8ykgsh70t
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift. The test now subscribes, opens the gate, awaits `MountFixtures.settledTerminal(of:in:)` (the mailbox settlement, which already records an issue when the run does not settle), closes the session, and drains the stream with the existing `collect(_:)` helper. No wall clock remains in the test; `SessionEventLog`, the `collecting` Task and `BoundedWait.conditionReached` are gone from it. The `SessionEventLog` doc comment lost the clause about the removed usage.
    - evidence: RED — before the edit, `taskpolicy -c background swift test --skip-build` beside 36 `yes` hogs failed this test 3 of 3 runs with the card's exact issues (`BoundedWait.swift:114` and `ToolInvocationLivenessTests.swift:553`). GREEN — after the edit, the same harness passed this test 3 of 3 runs (24.5 s, 9.3 s and 8.9 s under starvation); runs 2 and 3 were green for all 1238 tests, run 1 (68 s suite time) failed only `BoundedWaitTests` late-signal, recorded as task ^d3fbqz7.
    - evidence: `swift test --filter ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` -> `Test run with 1 test in 1 suite passed`, 17 ms, no compiler warning beyond the known mlx bundle line. Ten consecutive `swift test` runs -> each `Test run with 1238 tests in 134 suites passed ... with 2 known issues` and `83 tests in 10 suites passed`, exit 0 each time.
    - discovered: `reportPostedBetweenTurnsArrivesOnTheSessionStream` in the same file has the same shape (main-actor `collecting` Task plus a 5 s bound) and is out of this card's scope; recorded as task ^7a0qs4p. The throttled harness is `throttled-runs.sh` in the session scratchpad.
    - next: /review
  timestamp: 2026-09-08T14:52:23.131774+00:00
- actor: claude-code
  id: 01m20ra3217bv4vhsn62kvn1kf
  text: |-
    ### test — green

    - Command: `swift test` (full suite, fresh recompile confirmed via `.o` mtime newer than the edited source file).
    - Counts: 1238 tests in 134 suites passed (2 known issues, both pre-existing intentional `withKnownIssue` cases unrelated to this change) + 83 tests in 10 suites passed. Total 1321 passed, 0 failed, 0 skipped.
    - Build: `Build complete! (1.99 sec)`, no `warning:` lines from the Swift compiler (the one "warning: missing creator for mutated node" line is an unrelated SwiftPM build-system/bundle-plist message, not a Swift diagnostic against this file).
    - Targeted check: `swift test --filter 'FoundationModelsRouterTests.ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles'` run 3 times in isolation — each run reports "Test run with 1 test in 1 suite passed" (confirms the filter matches, non-zero count), passing in ~0.01s each time. In the full parallel run it passed in 3.161s with no timeout — the fix (subscribing to `streamSessionEvents()` before `gate.open()`, waiting on `MountFixtures.settledTerminal` via the mailbox instead of `BoundedWait` polling a log, then draining with `collect(sessionEvents)` after `fixture.session.close()`) removes the wall-clock race under load.
    - No skipped/ignored tests found; the "skipped" text matches were all test-name narrative (e.g. "throws sidecarMissing rather than being skipped"), not actual skips.
    - No code changes were needed beyond what was already in the working tree — reviewed the diff in `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift` and confirmed `MountFixtures.settledTerminal(of:in:)`, `collect(_ stream: AsyncStream<SessionEvent>)`, and `RoutedSession.close()` all exist with matching signatures, and that `SessionEventLog`'s trimmed doc comment still matches its one remaining use in `reportPostedBetweenTurnsArrivesOnTheSessionStream`.
  timestamp: 2026-09-08T14:56:15.425352+00:00
position_column: doing
position_ordinal: '80'
title: A background-call liveness test times out under a full parallel test run
---
### What

`ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` failed one time in a full `swift test` run of 1238 tests, and passed alone (14 ms) and on the next full run.

The failure: `BoundedWait.conditionReached("the report on streamSessionEvents()")` was never satisfied inside its bound, so `expectOneReportFollowsClose(in:)` found no report. In the failing run, many unrelated tests reported durations near 7.8 seconds, so the machine was under load when the wall-clock bound expired.

Found while implementing ^9hdy3hq. That card did not change this path: it changed only the schema JSON encoder in `TranscriptEntryMapper`.

### What to do

- [x] Reproduce the timeout under load, for example with a full `swift test` run repeated several times.
- [x] Find whether the bound is too short under load, or whether the report can be lost when the run settles before the session stream is subscribed.
- [x] Make the test deterministic: subscribe before the run can settle, or wait on the mailbox settlement instead of a wall clock, as the test's own comment intends.

### Acceptance Criteria

- [x] The test passes in ten consecutive full `swift test` runs.
- [x] No timeout is raised to hide the cause.