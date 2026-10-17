---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54b0y7hrkwf9zzx706smq4w
  text: |-
    ### Research
    - Both waits (`ConcurrencyPeakObserver.waitUntil`, `PassBoundaryLog.waitUntil`) keep a list of `Waiter { condition, continuation }` and resume only on a record. Neither has a cancel handler.
    - `ChangeSignal` of the router target is `internal`. The support target imports the router without `@testable`, so it cannot use it. To make it `package` is a production change only for a test hook, which is forbidden. Thus the fix stays in the support target.
    - Design: one new type in the support target, `ConditionWaitList<Value>`: a value and its waiters under one `Mutex`, in the form of `AwaitedEvent.wait()` and `ChangeSignal.waitForChange(after:)` (`withTaskCancellationHandler`, cancel read inside the lock). Both helpers use it, so the cancel logic has one copy. A `Mutex` and not an actor hop, so the cancel handler resumes the wait at once and starts no unstructured task.
    - The waits become `async throws` and throw `CancellationError` on a cancel. A cancel comes before the condition, so a cancelled wait never returns as if the state came.
    - IntegrationTests: no direct caller of the two waits. `ExecutorPassBoundaryIntegrationTests` calls `PassBoundaryExpectations.consumeAfterEachOpenPassEnds`, which already `throws`, so its signature does not change.
    - `consumeAfterEachOpenPassEnds` (the `log.waitUntil { hasNoOpenPass($0) }` site): the failure is a pass that keeps its end until the consumer reads the next element. The consumer does not read the stream while it waits, so the stream end cannot come, and the test makes no close. No failure event exists; the site keeps the wait with a comment (decision Group 2 of `^5xy53sw`).
  timestamp: 2026-10-17T07:08:07.281130+00:00
- actor: claude-code
  id: 01m54bbsxb0k14g9zmwj6ba9dw
  text: |-
    ### Implementation
    - New `Tests/FoundationModelsRouterTestSupport/ConditionWaitList.swift`: a value and its waits under one `Mutex`. `update(_:)` changes the value and resumes each wait whose condition holds. `wait(until:)` is `async throws`: `withTaskCancellationHandler`, the cancel is read inside the lock, and the cancel handler removes the wait by ticket and resumes it. A cancel comes before the condition, so a cancelled wait throws `CancellationError` also when the condition holds later.
    - `ConcurrencyPeakObserver.waitUntil(_:)` and `PassBoundaryLog.waitUntil(_:)` now forward to it and are `async throws`. The observer keeps its actor counts and gives a `Counts` snapshot to the list after each `enter()`/`exit()`. The log keeps its events in the list. The docs now say that the wait ends on a cancel, and that a test with a failure event wraps it in `RecordedWaitResult.wait(for:endingOnEndOf:)`.
    - Wrapped sites (PoolEntryQueueTests, NestedGenerationReentryTests, QueuedPassStallWatchTests two sites): now `try await`; the cancel of the wait task now ends the inner wait.
    - Sites with no failure event before (GenerationQueueTests two sites, SummarizerSubmissionTests, SharedGenerationQueueContentionTests): now `RecordedWaitResult.wait(for:endingOnEndOf:)` with the end of the answer or call task that must enter. In SummarizerSubmissionTests the throw goes to the existing `catch`, which opens the flash latch.
    - Site left with a reason: `PassBoundaryExpectations.consumeAfterEachOpenPassEnds` (`log.waitUntil { hasNoOpenPass($0) }`). The failure is a pass that keeps its end until the consumer reads the next element. The loop does not read the stream while it waits, so the stream end cannot come, and no close or settle exists there. The site keeps the wait (now `try await`, so a cancel of the reading task ends it) with a one-line comment (decision Group 2 of `^5xy53sw`).
    - New test `Tests/FoundationModelsRouterTests/SupportWaitCancellationTests.swift`: two tests (observer and log) cancel the waiting task, then make the condition hold, and expect `CancellationError`. RED before the change: both failed with "an error was expected but none was thrown". GREEN after.
    - IntegrationTests: no direct caller of the two waits; `swift build --build-tests --package-path IntegrationTests` builds (Build complete).
    - Full suite one time (`swift test`): FoundationModelsRouterTests 1821 tests in 223 suites passed, with 4 known issues (the existing `withKnownIssue` tests); PublicSurfaceTests 26 tests in 14 suites passed; Evals 19 tests in 3 suites passed. XCTest: 0 tests. No compiler warning (only the existing SwiftPM line "missing creator for mutated node" of the mlx bundle).
  timestamp: 2026-10-17T07:14:03.307727+00:00
- actor: claude-code
  id: 01m54bc27rfwyqrcjbax0dfhkc
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Tests/FoundationModelsRouterTestSupport/ConditionWaitList.swift, Tests/FoundationModelsRouterTests/SupportWaitCancellationTests.swift. Changed: Tests/FoundationModelsRouterTestSupport/ConcurrencyPeakObserver.swift, Tests/FoundationModelsRouterTestSupport/ExecutorPassBoundaryProbe.swift, Tests/FoundationModelsRouterTests/{GenerationQueueTests,SummarizerSubmissionTests,SharedGenerationQueueContentionTests,PoolEntryQueueTests,NestedGenerationReentryTests,QueuedPassStallWatchTests}.swift. `swift test`: 1821 tests in 223 suites passed (4 known issues), 26 in 14 passed, 19 in 3 passed. IntegrationTests build complete.
    - next: review
  timestamp: 2026-10-17T07:14:11.832990+00:00
- actor: claude-code
  id: 01m54bjfnkxv5656qrpngqkskx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit b9f843fe). Counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0, skipped 0. The engine reviewed 10 files. The .reviewignore rule excluded 2 .kanban files.
    - next: The task is in done. No work remains.
  timestamp: 2026-10-17T07:17:42.195462+00:00
- actor: claude-code
  id: 01m54bk0jp3dvv1rpe49yxe0x1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 test files
    - test: green — the one full swift test run of the implement step: 1821 tests in 223 suites + 26 + 19 passed; IntegrationTests build complete
    - commit: b9f843fe
    - review: clean — 0 findings, 10 files reviewed
  timestamp: 2026-10-17T07:17:59.510041+00:00
depends_on:
- 01M546DDX24X6X0Q36H404VFSZ
position_column: done
position_ordinal: fffffffe80
title: 'T1 follow-up 4/6: ConcurrencyPeakObserver and PassBoundaryLog waits end on a cancel'
---
Source: task ^dbr1dqy (T1 audit, done). The audit comment "kinds of waits checked and left" names this helper change as not made: `ConcurrencyPeakObserver.endWaits()`. Reason given: ConcurrencyPeakObserver `waitUntil` has no way to end a wait.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

Helpers (checked against the code on 2026-10-17). Both are in the test helper target Tests/FoundationModelsRouterTestSupport (not production code), so a change is permitted:
- `ConcurrencyPeakObserver.waitUntil(_:)` in Tests/FoundationModelsRouterTestSupport/ConcurrencyPeakObserver.swift:84. It suspends on `withCheckedContinuation` with no cancel handler. Only an `enter()` or `exit()` resumes it.
- `PassBoundaryLog.waitUntil(_:)` in Tests/FoundationModelsRouterTestSupport/ExecutorPassBoundaryProbe.swift:103. The same form; only a record resumes it.

Problem: two sites already wrap the observer wait in `RecordedWaitResult.wait(for:endingOnEndOf:)`, but the cancel of the wait task does not end the inner wait, so a task stays suspended after the test. The other sites have no failure event.

Failure event to use: the end of the answer task that must enter the section (it already exists), through `RecordedWaitResult.wait(for:endingOnEndOf:)` (Tests/FoundationModelsRouterTests/Helpers/RecordedWaitResult.swift:105).

Plan:
- [x] Make `ConcurrencyPeakObserver.waitUntil(_:)` end on a cancel (for example `withTaskCancellationHandler` that removes the waiter and resumes it), or add `endWaits()`. Choose the form yourself. Keep each existing caller correct (the doc says a body that never enters keeps the test waiting; update the doc).
- [x] Make `PassBoundaryLog.waitUntil(_:)` end on a cancel in the same form.
- [x] Check the IntegrationTests package: it imports FoundationModelsRouterTestSupport. Search IntegrationTests for callers of both waits and keep them correct. Build it with `swift build --build-tests --package-path IntegrationTests`.
- [x] Sites that already wrap the wait (check that the inner task now ends): PoolEntryQueueTests.swift:188; NestedGenerationReentryTests.swift:1038; QueuedPassStallWatchTests.swift:200, 281 (`toolLog.waitUntil`).
- [x] Sites with no failure event (change to the wrapped form with the answer end): GenerationQueueTests.swift:67, 125; SummarizerSubmissionTests.swift:89; SharedGenerationQueueContentionTests.swift:88.
- [x] ExecutorPassBoundaryProbe.swift:414 (`log.waitUntil { hasNoOpenPass($0) }`, inside the support target): check and change it when a failure event exists.
- [x] For each site where no event comes in the failure, leave the site and write the reason in a comment on this card.
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup