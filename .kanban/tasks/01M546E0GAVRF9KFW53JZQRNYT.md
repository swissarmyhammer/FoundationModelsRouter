---
assignees:
- claude-code
depends_on:
- 01M546DDX24X6X0Q36H404VFSZ
position_column: todo
position_ordinal: '8380'
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
- [ ] Make `ConcurrencyPeakObserver.waitUntil(_:)` end on a cancel (for example `withTaskCancellationHandler` that removes the waiter and resumes it), or add `endWaits()`. Choose the form yourself. Keep each existing caller correct (the doc says a body that never enters keeps the test waiting; update the doc).
- [ ] Make `PassBoundaryLog.waitUntil(_:)` end on a cancel in the same form.
- [ ] Check the IntegrationTests package: it imports FoundationModelsRouterTestSupport. Search IntegrationTests for callers of both waits and keep them correct. Build it with `swift build --build-tests --package-path IntegrationTests`.
- [ ] Sites that already wrap the wait (check that the inner task now ends): PoolEntryQueueTests.swift:188; NestedGenerationReentryTests.swift:1038; QueuedPassStallWatchTests.swift:200, 281 (`toolLog.waitUntil`).
- [ ] Sites with no failure event (change to the wrapped form with the answer end): GenerationQueueTests.swift:67, 125; SummarizerSubmissionTests.swift:89; SharedGenerationQueueContentionTests.swift:88.
- [ ] ExecutorPassBoundaryProbe.swift:414 (`log.waitUntil { hasNoOpenPass($0) }`, inside the support target): check and change it when a failure event exists.
- [ ] For each site where no event comes in the failure, leave the site and write the reason in a comment on this card.
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup