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
- actor: claude-code
  id: 01m3fhbhqdtkmnncmmnb42fp7a
  text: |-
    Picked up. Name mapping (from `git log -S` on HumanWaitGateTests.swift):
    - `turnEndingDuringAReAcquireStrandsNoPermit` became `turnEndingDuringAnOutOfTurnWaitStrandsNothing` in 38ece0e (^93kjn94).
    - `turnEndingDuringAnOutOfTurnWaitStrandsNothing` became `answerEndingDuringAWaitOutsideASubmissionStrandsNothing` in 73a2e85 (^f33q8gw).
    - The suite is still `HumanWaitGateTests` (Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift).

    Scenario check: the old test was about a permit re-acquire race. The permit, the re-acquire and `awaitingUser` are gone. The current test keeps the same shape (answer A ends while a wait outside any submission is open, answer B waits behind A on the same model, then both sessions answer again). So it is the successor, but the old race cannot occur now.

    Discovery: the current test (and all tests of the suite except `waitOverlappingAnotherAnswerLeavesTheSessionIdle`) waits through `BoundedWait.awaitSignal` / `conditionReached` / `completedRun`, which give up after a 5 s wall clock (`BoundedWait.ceilingNanoseconds`). This is the same cause as ^zr22hpd and ^7w145zc. `waitOverlappingAnotherAnswerLeavesTheSessionIdle` was already moved to `AwaitedEvent` plus `.timeLimit(.minutes(1))` in ^q8cnmb2. The second comment on this task records the same symptom in `forkRacingAHumanWaitReadsTheSettledTranscript` of the same suite. Machine: 18 cores; load average at pickup 15 to 25 (four sourcekit-lsp processes at 100 % each).
  timestamp: 2026-09-26T18:59:01.485265+00:00
- actor: claude-code
  id: 01m3fj8aqwjp3523aabmk82mvt
  text: |-
    Reproduction attempt (tree at 1d7fec1, 18 cores, background load about 11 to 16 from four sourcekit-lsp processes). Method: `swiftpm-testing-helper` on the built bundle (memory note method). Load is the 1-minute average, sampled every 5 s.
    - 60 full-suite runs, one after the other (`sequential.sh`, 20 + 40): 59 x "Test run with 1458 tests in 171 suites passed"; load 14.7 to 21.1. 0 issues in HumanWaitGateTests. Run 38 of the second 40 crashed (exit 134, see the next comment); this is not this test.
    - `HumanWaitGateTests` alone, 8 processes x 200 repetitions (14,400 test runs): 0 issues, load 16.5 to 21.6.
    - `HumanWaitGateTests` alone, 6 processes x 1000 repetitions (54,000 test runs): 0 issues, load 18.9 to 23.9.
    - Note: one full-suite process with `--repetitions 20` alone takes the load to 37, so a full-suite load above 18 cannot be avoided; the recorded failures (load 19 to 23) were in plain full runs.
    Result: no failure at load up to about 18 to 24 after a fair run. Per the stress limit, I do not file a new task.

    Deterministic proof of the cause (RED): I put `try? await Task.sleep(for: .seconds(6))` before `inAnswerA.signal()` in the hook of `answerEndingDuringAWaitOutsideASubmissionStrandsNothing` (a correct but slow run). `swift test --filter HumanWaitGateTests/answerEndingDuringAWaitOutsideASubmissionStrandsNothing` then gives "Test run with 1 test in 1 suite failed after 5.012 seconds with 2 issues" (the bound issue plus `SignalNeverArrived`). So a slow run, not an ordering race, fails the test. The cause is the 5 s wall clock of `BoundedWait` (`awaitSignal`, `conditionReached`, `completedRun`, `becomesIdle`) under scheduler starvation of the @MainActor test.

    Decision (the test clearly uses a wall clock): change every wait of the suite to a real signal, with the suite `.timeLimit(.minutes(1))` as the only fault ceiling, as ^q8cnmb2 did for `waitOverlappingAnotherAnswerLeavesTheSessionIdle`:
    - moments inside the hook: `AwaitedEvent` that the hook signals;
    - the end of an answer or of a wait task: `AwaitedEvent` that the task signals when it ends;
    - sessionB waiting behind sessionA: `SessionEvent.submissionQueued` on `sessionB.streamSessionEvents()` (the queue sends it when the item joins the waiting list);
    - the session becoming idle: the end of `RoutedSessionActor.pumpTask` itself, then the outbox count;
    - the fork: an `AwaitedEvent` that the fixture backend signals in `makeFork`;
    - the second message in the outbox: no event exists, so a read with no deadline that only the `.timeLimit` (cancellation) ends.
  timestamp: 2026-09-26T19:14:44.604179+00:00
- actor: claude-code
  id: 01m3fj8dww3k1nynkjbg2m3z26
  text: 'Other timing failure seen during the stress (not filed as a task, per the instruction): full-suite run 38 of 40 (`sequential.sh before-seq2`, load 15 to 21) aborted with exit 134 and the last line "Object 0x76efe2a580 of class _ContiguousArrayStorage deallocated with non-zero retain count 2. This object''s deinit, or something called from it, may have created a strong reference to self which outlived deinit, resulting in a dangling reference." This is the signature of the stub backend producer race (^9smkhk8 memory note): an array read while another task frees it. The log does not name the test that ran. 1 crash in 60 full runs.'
  timestamp: 2026-09-26T19:14:47.836311+00:00
- actor: claude-code
  id: 01m3fjypkqwqd31jzbjfzf7a44
  text: |-
    Cause. The failing test waited through `BoundedWait.awaitSignal` at three points: "sessionA's answer reaching the model", "the human wait outside any submission being entered" and "sessionB's answer reaching the model" (plus `conditionReached`, `completedRun` and `becomesIdle`, which use the same clock). The original logs kept only `SignalNeverArrived()` and not the issue label, so it is not possible to name which of the three timed out. All of them share one cause: each gives up after the 5 s wall clock of `BoundedWait.ceilingNanoseconds`. Evidence that the cause is CPU load and not an ordering race:
    - Each signal is sent unconditionally by the path that reaches it; no order of events can skip it. The permit re-acquire race that the old name described does not exist in the code now.
    - A correct but slow run fails the same way: a 6 s delay before `inAnswerA.signal()` gives `SignalNeverArrived` after 5.012 s.
    - 68,400 runs of the suite at load 16.5 to 23.9 gave 0 failures; all recorded failures were in full runs at load 19 to 23, where the @MainActor tests share one main actor with the whole suite.
    - `forkRacingAHumanWaitReadsTheSettledTranscript` failed the same way (second comment) although its fork path has no wait at all.
  timestamp: 2026-09-26T19:26:57.655416+00:00
- actor: claude-code
  id: 01m3fjz104wx5y2qb5e2ydj1sq
  text: |-
    Implementation (no production code changed; no lock; no new name with "turn"):
    - `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift`: the suite has `.timeLimit(.minutes(1))` (the per-test one on `waitOverlappingAnotherAnswerLeavesTheSessionIdle` moved to the suite). All 9 tests wait on real signals: `AwaitedEvent`s that the hook sends; `ObservedRun` (a task plus the `AwaitedEvent` it sends when it ends, replaces `completedRun`/`completedAnswer`/`followUpAnswerCompletes` and every `guard ... else { return }`); `submissionQueued(on:)` reads `SessionEvent.submissionQueued` from `streamSessionEvents()` (replaces the poll of `queue.waitingCount`); `HookedSessionBackend.forkMade` (replaces the poll of `lastFork`); `followUpAnswer` now asserts the exact reply, not only "not nil". The one state with no event (a message in the outbox) uses `AwaitedCondition`.
    - `Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift`: new `isIdleOnceThePumpEnds()`, which waits for the end of `RoutedSessionActor.pumpTask` itself and then reads the outbox. `becomesIdle()` is unchanged for its other callers.
    - `Tests/FoundationModelsRouterTests/Helpers/AwaitedCondition.swift` (new): a read with no deadline that only cancellation ends; throws `ConditionNeverHeld`.
    - `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`: the yield-then-poll loop of `spin(until:)` moved into `poll(until:givingUpWhen:)`, which `spin` (wall clock) and `AwaitedCondition` (cancellation) share. `spin` behaves as before.
    - `Tests/FoundationModelsRouterTests/AwaitedConditionTests.swift` (new, 3 tests): holds at once; holds only 1 s after the `BoundedWait` ceiling and is still seen; a cancelled wait throws. RED first: "cannot find 'AwaitedCondition' in scope"; then 3 passed.
    The time limit is not raised to hide the fault: no wait in the suite has a time verdict now; the 1-minute trait only ends a real hang, the same pattern as ^q8cnmb2, `AnswerCancellationTests` and `AwaitedEventTests`.

    Verification:
    - GREEN with the same 6 s delay in the hook: `swift test --filter HumanWaitGateTests` gave "Test run with 9 tests in 1 suite passed after 6.389 seconds" (the target test passed after 6.388 s). The delay was then removed.
    - `stress.sh after-suite-p6 6 1000 HumanWaitGateTests`: 6 x "Test run with 9 tests in 1 suite passed" (9002 started lines per process, 54,000 test runs), 0 issues, load 12.4 to 21.7.
    - `sequential.sh after-seq 30`: 30 x "Test run with 1461 tests in 172 suites passed", 0 issues, load 14.2 to 20.8.
    - `swift test`: 1461 + 17 + 19 = 1497 (1494 + 3 new tests), exit 0; the only warning is the known mlx-swift "missing creator for mutated node".
  timestamp: 2026-09-26T19:27:08.292375+00:00
- actor: claude-code
  id: 01m3fjzczma14jgps7psd2jmv0
  text: |-
    ### implement — changed
    - evidence: cause = the 5 s wall clock of `BoundedWait` under scheduler starvation (CPU load), not an ordering race. Files: Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift, Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift, Tests/FoundationModelsRouterTests/Helpers/AwaitedCondition.swift (new), Tests/FoundationModelsRouterTests/AwaitedConditionTests.swift (new). Before: 60 full runs (load 14.7-21.1) + 68,400 suite runs (load 16.5-23.9), 0 failures; 6 s hook delay fails after 5.012 s. After: 6 s hook delay passes; `stress.sh after-suite-p6 6 1000 HumanWaitGateTests` 54,000 runs 0 issues (load 12.4-21.7); `sequential.sh after-seq 30` 30/30 x 1461 passed (load 14.2-20.8); `swift test` 1461 + 17 + 19 = 1497, only the known mlx warning. Other timing failure (not filed): 1 crash in 60 full runs, "_ContiguousArrayStorage deallocated with non-zero retain count 2".
    - next: /review
  timestamp: 2026-09-26T19:27:20.564256+00:00
- actor: claude-code
  id: 01m3fkhwhfz9xqrxke140fe5bp
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 53d7979). 0 findings, 0 confirmed, 0 refuted. The engine examined 5 files. It did not examine 2 files in `.kanban/` because of `.reviewignore`. The task had no earlier findings.
    - next: The task is in done. Nothing more to do.
  timestamp: 2026-09-26T19:37:26.319778+00:00
- actor: claude-code
  id: 01m3fkkv3ng3twmbkaf98cacec
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 test files (waits on real signals; AwaitedCondition; no wall clock); cause was the 5 s wall clock under CPU starvation
    - test: green — swift test, 1497 passed (1461+17+19), 0 failed, 0 skipped; 28 BoundedWait suites 3 extra runs clean
    - commit: 53d7979
    - review: clean — 0 findings
  timestamp: 2026-09-26T19:38:30.389987+00:00
position_column: done
position_ordinal: ffffff9a80
title: Investigate a timeout of HumanWaitGateTests turnEndingDuringAReAcquireStrandsNoPermit under full-suite load
---
## What happened

On 2026-09-25, during the implement step of ^tv2yt7s, one full `swift test` run of the root package failed one test:

- `HumanWaitGateTests` / "a turn ending while a human wait's re-acquire is in flight strands no permit: the model family keeps generating"
- `BoundedWait.swift`: Issue recorded; `HumanWaitGateTests.swift`: Caught error: `SignalNeverArrived()`

## Name mapping

- `turnEndingDuringAReAcquireStrandsNoPermit` became `turnEndingDuringAnOutOfTurnWaitStrandsNothing` (38ece0e, ^93kjn94), then `answerEndingDuringAWaitOutsideASubmissionStrandsNothing` (73a2e85, ^f33q8gw). The suite is still `HumanWaitGateTests`. The permit re-acquire is gone; the current test keeps the same scenario shape.

## Measurements

- The same tree: 1 failure in 24 full runs. The suite alone: 0 failures in 8 runs.
- The tree before ^tv2yt7s (baseline): 0 failures in 12 full runs.
- The test resolves its fixture first and then drives only the session turn gates. The ^tv2yt7s change touches only the pool acquire and release paths, which end before the part of the test that timed out.

## What to do

- [x] Reproduce with parallel repetitions of the full suite (see the memory note about the stub backend producer race for the method). Proof: the reproduction comment — 60 full runs (load 14.7 to 21.1) and 68,400 suite runs in 6 and 8 parallel processes (load 16.5 to 23.9) gave 0 failures, so the failure does not occur at load up to about the core count; a 6 s delay in the hook reproduces it deterministically ("failed after 5.012 seconds with 2 issues").
- [x] Find which `BoundedWait.awaitSignal` timed out, and if the cause is CPU load or a real ordering race. Proof: the cause comment — CPU load (scheduler starvation of the @MainActor test past the 5 s wall clock of `BoundedWait`), not an ordering race.
- [x] Fix the cause. Do not raise the time limit to hide it. Proof: the implementation comment — every wait of the suite now ends on a real signal (no wall clock); the same 6 s delay passes ("passed after 6.388 seconds"); 54,000 suite runs and 30 full runs after the change gave 0 failures.

#test-flake