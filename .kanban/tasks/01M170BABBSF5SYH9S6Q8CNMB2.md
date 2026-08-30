---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m175gr56rqdxjgtcp7yjh1k8
  text: |-
    Picked up. Reproduced both failure shapes on a loaded machine.

    Method: 32-core machine, a background script with 1024 busy shell loops, load average 550 to 990. `swift test` (full suite) repeated.

    Measurements:
    - 128 busy workers (load ~210): 3 full runs, no card failure. One other flake appeared: `RecordingLanguageModelTests.swift:514` `generationGate.availablePermits == 0`.
    - 512 busy workers (load ~210 to 550): 5 full runs, all passed.
    - 1024 busy workers (load ~554): run 1 gave the card's failure exactly — "a streaming turn reports the stall against the fragments it counted" recorded `BoundedWait.swift:114` and then `GenerationStallDiagnosticTests.swift:292 Expectation failed: reported`. Run 2 gave a SECOND, different failure of the same test: `GenerationStallDiagnosticTests.swift:294 Expectation failed: stall.visibility == .fragments(observed: producedFragments)`.

    The second failure names the root cause. The test waits on `backend.suspended`, which the stalling backend signals as soon as it has pushed its chunks into the `AsyncThrowingStream` buffer. That is not the event the test is about. The session counts a fragment in `noteGenerationFragment()` only when it *reads* the chunk, so under load the stall report can be published while chunks are still unread, and it then carries `observed: 0` or `1` instead of `2`. Waiting on the correct event — the session having counted the fragment, which the turn's own `.fragment` element proves — removes both the wrong count and the poll.

    Probe: setting `BoundedWait.yieldsBeforePolling` to 0 and repeating 3 full runs at load average 985 produced no failure. Consistent with the yield spin crowding the cooperative pool, but not proof. The probe was reverted; `BoundedWait` is not changed.
  timestamp: 2026-08-29T16:26:49.894091+00:00
- actor: claude-code
  id: 01m178cpbvtmpww58mxjptz444
  text: |-
    What the fix does.

    New test helper `AwaitedEvent` (Tests/FoundationModelsRouterTests/Helpers/AwaitedEvent.swift). A one-shot event a test waits ON, rather than polls a proxy of. The producer resumes the waiter, so a loaded machine makes the wait longer and never wrong. Written with TDD: `AwaitedEventTests.swift` was written first and failed to compile ("cannot find 'AwaitedEvent' in scope"), then the type made it pass.

    The suspension is cancellation-aware, which `AsyncSemaphore.wait()` is not and must not become — its non-cancellable contract is what keeps a gate permit from being abandoned half way. That makes the `.timeLimit(.minutes(1))` trait able to end a test whose event never arrives, so no wait has to give up early to keep the suite from hanging. Measured with a throwaway probe test: a wait on an event nothing sends recorded "Time limit was exceeded: 60.000 seconds" and the run ended cleanly. The probe was removed.

    `GenerationStallDiagnosticTests` streaming test: it now reads the turn's own event stream in the test task. Each element is a suspension the turn resumes. It counts `.textDelta` elements and takes the first `.generationStalled` that comes AFTER every fragment was counted. The session counts a fragment before it publishes the matching `.textDelta`, so that report was measured against every fragment the turn produced. This also removes the second failure shape: a report made while a chunk was still unread carries a smaller count, honestly, and a stalled generation reports again on each further interval, so the report the test is about always follows. The `suspended` signal is gone from the backend's streaming path, because nothing reads it there any more.

    `HumanWaitGateTests` overlapping test: every moment it waits for is an `AwaitedEvent` now. The semaphores that stay are the ones the test SIGNALS rather than waits on — a release the test itself makes always arrives. `completedTurn`, `completedRun` and `followUpTurnCompletes` are untouched and still serve the other tests of the suite.

    `BoundedWait` is unchanged.
  timestamp: 2026-08-29T17:17:02.715895+00:00
- actor: claude-code
  id: 01m178cwwav3xmba5xyecmxyxf
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterTests/Helpers/AwaitedEvent.swift (new), Tests/FoundationModelsRouterTests/AwaitedEventTests.swift (new), Tests/FoundationModelsRouterTests/GenerationStallDiagnosticTests.swift, Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift. Quiet: `swift test` — 1110 tests in 119 suites passed after 5.075 seconds with 2 known issues; 83 tests in 10 suites passed. Loaded: 1024 busy shell loops on 32 cores, load average 954 to 1022; 12 full `swift test` runs in two rounds of 6, every run 1110 tests in 119 suites passed, 27.4 to 33.9 seconds each. The same load reproduced the card's failure twice before the fix.
    - next: /review
  timestamp: 2026-08-29T17:17:09.386215+00:00
- actor: claude-code
  id: 01m19a4tbkam0ry4w9mj4ykyxv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (dfb1da8) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 4 source files reviewed; 10 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done. No open findings.
  timestamp: 2026-08-30T12:26:10.675145+00:00
- actor: claude-code
  id: 01m19a5cd806s395y9ve1fvet3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — done in an earlier session; 4 files, uncommitted in the tree when this loop started
    - test: green — `swift test`, pass 1: 1110 tests in 119 suites, pass 2: 83 tests in 10 suites, 0 failed, 0 skipped
    - commit: dfb1da8 — test(router): wait on the event, not the clock, in two flaky suites
    - review: clean — 0 findings, 7 validators, task moved to done
  timestamp: 2026-08-30T12:26:29.160693+00:00
position_column: done
position_ordinal: ffffa180
title: Two wall-clock test suites fail when the machine is under load
---
## What

Seen while running `swift test` during ^tf6dwx1, with `swiftlint` running at the same
time on the same machine. Two suites failed on that run and on that run only:

- `GenerationStallDiagnosticTests` — "a streaming turn reports the stall against the
  fragments it counted". `GenerationStallDiagnosticTests.swift:292` reported
  `Expectation failed: reported`, after `BoundedWait.swift:114` recorded its
  give-up issue.
- `HumanWaitGateTests` — "a human wait overlapping a turn it is not part of leaves
  the gate at exactly one permit". `HumanWaitGateTests.swift:738` threw
  `RunNeverFinished()`, after the same `BoundedWait.swift:114` give-up.

Both then passed on their own:

    swift test --filter "HumanWaitGateTests|GenerationStallDiagnosticTests"
    Test run with 15 tests in 2 suites passed after 1.985 seconds.

And the whole suite passed on a quiet machine, before and after:

    swift test
    Test run with 1106 tests in 118 suites passed after 5.021 seconds with 2 known issues.

So the two tests are timing-sensitive. `BoundedWait` ends a wait on a wall clock. When
another process takes the cores, the work under measurement does not finish inside that
wall-clock window, and the wait gives up on work that was only slow.

Raising the timeout is not the fix. The fix is to make each of the two tests wait on the
event it is really about, so a slow machine makes the test slower and never red.

## Acceptance Criteria
- [x] Neither test measures progress against a wall clock alone.
- [x] Both tests pass with the machine loaded. Run `swift test` while a second heavy
      process runs, and repeat it several times.
- [x] `BoundedWait` keeps its own contract. Do not weaken it for these two callers.

## Tests
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #tests #router-tests