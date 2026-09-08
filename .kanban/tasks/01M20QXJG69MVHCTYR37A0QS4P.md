---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20rm5shszh9m76q624shg33
  text: |-
    Picked up. Research result:

    Delivery chain for a report posted between turns, read from the code:
    - `SessionOutbox.post(report:)` does `await invocationObserver?.deliver(report:)`. The observer is the session actor (`RoutedSessionActor.deliver(report:)` in RoutedSessionActorRunJournal.swift), which is a synchronous actor method that calls `deliverLive(.toolCallReport(report))`.
    - Between turns `currentTurnEventSink` is nil, so `deliverLive` calls `emitSessionScopedEvent`, which does `continuation.yield(event)` on each `streamSessionEvents()` subscription. The stream buffer is `.unbounded`.
    - So when `await outbox.post(report:)` returns, the report is already in the stream buffer. No wall clock is necessary.
    - `RoutedSessionActor.close()` calls `finishSessionEventSubscriptions()` first, before any early return. So a close after the post finishes the stream, and `collect(_ stream: AsyncStream<SessionEvent>)` in Tests/FoundationModelsRouterTests/Helpers/SessionEventCollection.swift drains it to the end.

    The test today: `@MainActor`, a `collecting` Task that inherits the main actor, `SessionEventLog` actor, and `BoundedWait.conditionReached` with a 5 s bound. The shape is the one task ^z5pbt5e fixed in commit e8ba8d7.

    `SessionEventLog` has one reader: this test. After the change it has none, so the card asks for its deletion.

    Plan: build the tests, run the throttled harness (`taskpolicy -c background swift test --skip-build` beside 36 `yes` hogs) to show the failure or record why it does not fail, then change the test to: subscribe, post, close, `collect`, assert. Then run the same harness again and ten full `swift test` runs.
  timestamp: 2026-09-08T15:01:45.905635+00:00
- actor: claude-code
  id: 01m20sk5ynnnsrznyh49xp4nn8
  text: |-
    Harness result, before the change (RED): the test did NOT fail under the throttled harness. Three runs of `taskpolicy -c background swift test --skip-build` beside 36 `yes > /dev/null` hogs (`throttled-between.sh red 3 36` in the session scratchpad, logs `red-1..3.log`): the test passed in all three, at 9.8 s, 10.7 s and 9.4 s (14 ms alone). Run 2 was a hard starvation (152 s of suite time, 25 other tests hit their 60 s time limit) and the test still passed.

    Why it does not fail, read from the code: `BoundedWait.spin(until:)` spends 1000 cooperative `Task.yield()` calls before it reads the clock. In this test the report is already in the stream buffer when `await outbox.post(report:)` returns (the post awaits the session actor's synchronous `deliverLive`, which yields to every subscription), and the `collecting` Task was queued on the main actor before the post. So the first yields hand the main actor to that queued job, the hop from the stream to `SessionEventLog` completes, and the 5 s wall clock is never consulted. The sibling test's bound started after a long `mailbox.wait`, when the main-actor queue was deep with other test bodies, so its hop took more than 5 s. The shape is the same, and the wall clock still stands in the test, so the card's second item removes it anyway.

    The change: the test now subscribes, posts the report, closes the session (which finishes every session-event subscription first), drains the stream with the existing `collect(_:)` helper, and asserts `events.compactMap(\.carriedReport) == [report]`. `SessionEventLog`, the `collecting` Task and `BoundedWait.conditionReached` are gone from the file; `SessionEventLog` had no other reader, so it is deleted.

    Harness result, after the change (GREEN): `throttled-between.sh green 3 36`, logs `green-1..3.log`: the test passed in all three, at 8.6 s, 9.9 s and 8.5 s. Runs 1 and 2 were green for all 1238 tests. Run 3 was a hard starvation (118 s of suite time) and 27 other tests failed, 26 of them on `Time limit was exceeded: 60.000 seconds` (TurnCancellationTests, GenerationStallDiagnosticTests, MountedRunAttachmentCarrierTests, HumanWaitGateTests, ElicitationRoutingTests) and one on the expectation that follows such a time limit. That is the harness starving the process past the tests' own 60 s trait, the same shape run 2 of the RED harness showed on the unchanged tree; it is not a change in this card.

    Full runs: `swift test` twenty times (`ten-1..20.log`). Runs 1 to 9 and 11 to 20 each report `Test run with 1238 tests in 134 suites passed ... with 2 known issues` and `83 tests in 10 suites passed`; the test passed in each at 0.58 s to 1.0 s. Run 10 did not fail a test: the test process died with signal 5 about 0.45 s into the run, inside `RoutedSessionActor.recordTranscriptDelta` of a failed `streamResponse` turn. The changed test runs no streaming turn. Filed as a new task with the crash report. Runs 11 to 20 are ten consecutive green full runs.

    Every CPU hog was killed; `pgrep yes` finds none.
  timestamp: 2026-09-08T15:18:41.877139+00:00
- actor: claude-code
  id: 01m20sky8stdwb73vrq8at0qey
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift. `reportPostedBetweenTurnsArrivesOnTheSessionStream` now subscribes to `streamSessionEvents()`, posts the report, closes the session, drains the stream with the existing `collect(_:)` helper, and asserts `events.compactMap(\.carriedReport) == [report]`. The `SessionEventLog` actor, the `collecting` Task and the `BoundedWait.conditionReached` wall clock are deleted from the file. No production code changed.
    - evidence: RED harness (unchanged test) — `taskpolicy -c background swift test --skip-build` beside 36 `yes` hogs, 3 runs: the test passed 3 of 3 (9.8 s, 10.7 s, 9.4 s; 14 ms alone). It does not fail because `BoundedWait.spin` spends 1000 `Task.yield()` calls before it reads the clock, and the report is already buffered and the collecting job already queued on the main actor when the bound starts. Recorded on the card.
    - evidence: GREEN harness (changed test) — same harness, 3 runs: the test passed 3 of 3 (8.6 s, 9.9 s, 8.5 s). Runs 1 and 2 green for all 1238 tests; run 3 (118 s suite time) failed 27 unrelated tests on their own 60 s time limits, the same shape the RED harness run 2 showed on the unchanged tree.
    - evidence: `swift test --filter 'FoundationModelsRouterTests.ToolInvocationLivenessTests/reportPostedBetweenTurnsArrivesOnTheSessionStream'` -> `Test run with 1 test in 1 suite passed after 0.014 seconds`, no compiler warning beyond the known mlx bundle line.
    - evidence: `swift test` twenty times: runs 1-9 and 11-20 each `Test run with 1238 tests in 134 suites passed ... with 2 known issues` and `Test run with 83 tests in 10 suites passed`, exit 0, one known mlx warning each. Runs 11-20 are ten consecutive green full runs. Run 10: the test process died with signal 5 inside `RoutedSessionActor.recordTranscriptDelta` of a failed `streamResponse` turn, 0.45 s into the run, before any test recorded an issue; the changed test runs no streaming turn. Filed as task ^9smkhk8 with the crash report (`crash-ten-10.ips` in the session scratchpad).
    - evidence: no `yes` process remains (`pgrep yes` exits 1). Scratch scripts and logs: `throttled-between.sh`, `red-*.log`, `green-*.log`, `green-filtered.log`, `ten-*.log` in the session scratchpad.
    - next: /review
  timestamp: 2026-09-08T15:19:06.777869+00:00
- actor: claude-code
  id: 01m20srtpjh7m8vpxwgg9y34zw
  text: |-
    ### test — green
    - evidence: `swift test` (root package, both test targets) — 1238 tests in 134 suites passed (FoundationModelsRouterTests), 83 tests in 10 suites passed (FoundationModelsRouterEvalsTests). Total 1321 passed, 0 failed, 0 skipped, 2 known issues (pre-existing intentional `withKnownIssue` assertions in RealModelHarness and BoundedWait tests, unrelated to this change). Zero compiler warnings — confirmed `ToolInvocationLivenessTests.o` recompiled after the source edit (obj mtime after src mtime) with an empty `.dia` diagnostics file. No `RoutedSessionActor.recordTranscriptDelta` trap (^9smkhk8) occurred. Ran full suite twice, both green, exit code 0 both times.
    - next: ready for review.
  timestamp: 2026-09-08T15:21:46.962218+00:00
- actor: claude-code
  id: 01m20st805bj9ph5azgchj3syp
  text: |-
    ### commit — changed
    - evidence: 2113013 test(liveness): read the report from the stream, not from a wait (7 files changed)
    - next: none
  timestamp: 2026-09-08T15:22:33.349568+00:00
- actor: claude-code
  id: 01m20swyvggvkp71c082axj8by
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 2113013) — 0 findings, 7 validator pairs attempted, 0 failed. 1 file reviewed, 6 `.kanban/` files excluded by `.reviewignore`. No prior `## Review Findings` sections on the card.
    - next: none. The task moved from `review` to `done`.
  timestamp: 2026-09-08T15:24:02.288634+00:00
- actor: claude-code
  id: 01m20sxjp7z74rtdycqq8njzp0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file (Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift); new card ^9smkhk8 filed
    - test: green — swift test, 1238 passed + 83 passed in Evals, 0 failed, 0 skipped, 0 warnings
    - commit: 2113013
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-09-08T15:24:22.599873+00:00
position_column: done
position_ordinal: ffffcd80
title: The between-turns report liveness test waits on a wall clock from the main actor
---
### What

`ToolInvocationLivenessTests/reportPostedBetweenTurnsArrivesOnTheSessionStream` has the same shape that made `backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` time out under load (task ^z5pbt5e): the test is `@MainActor`, its `collecting` Task inherits the main actor, and `BoundedWait.conditionReached` gives that task 5 s of wall clock to move the report from the stream into `SessionEventLog`. Under a starved main actor the bound expires while the report sits in the stream buffer.

It has not failed yet. Task ^z5pbt5e reproduced the shape with `taskpolicy -c background swift test --skip-build` beside 36 `yes > /dev/null` hogs, and that harness is the way to show the failure and the fix.

### What to do

- [x] Show the test fails under the throttled harness, or record that it does not and why.
- [x] Remove the wall clock: `outbox.post(report:)` awaits the session actor's `deliverLive`, which yields to the stream before it returns, so after the post the report is already buffered. Close the session and drain the stream with `collect(_:)`, as the sibling test now does.
- [x] Delete `SessionEventLog` when no test reads it any more.

### Acceptance Criteria

- [x] The test passes in ten consecutive full `swift test` runs and under the throttled harness.
- [x] No timeout is raised to hide the cause.