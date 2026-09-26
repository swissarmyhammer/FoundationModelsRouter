---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cyx4ssskmcd10weq94j9jb
  text: |-
    From the design task ^jdp02p (2026-09-25, `generation-queue.md` sections 5.1, 5.3 and 5.5): what changes for this task.
    - The item of the queue becomes one submission to Foundation (one whole SDK call), not one pass (^1psqdm9). A summarizer call is thus one submission on the queue of the container that runs it. ^1psqdm9 step 3 builds that. This task now depends on ^1psqdm9, so it tests the final shape and does not test the per-pass shape twice.
    - AC1 (flash summarizer and a flash submission of another session never overlap) stays.
    - AC2 (own-model summarizer between two passes completes): restate it as "between two submissions". In the new model a compaction never runs inside a submission: the proactive check, the yield, the ceiling stop and the overflow retry all compact at the pump, between two submissions. The own-model summarizer thus never waits for its own session.
    - AC3 (cancel during a summarizer wait cancels via `isTurnCancelled`): until ^3qx0mpt the predicate is `isTurnCancelled`; after it, the predicate keys on the running answer. Keep the rule: key on the predicate, never on the type of `CancellationError`.
    - Step 2 (doc of `performAutoCompaction`) must name no `turnLock` and no `generationGate`.
  timestamp: 2026-09-25T18:58:06.265176+00:00
- actor: claude-code
  id: 01m3esjh0ddf7cw4k4jjcyjz0d
  text: |-
    Research (implement step, HEAD 9df76c4).
    - The production work is already done by ^1psqdm9. `runCompaction` gives each summarizer tier a `CancellableCompactionSummarizer`. Each call of it goes through `runCancellableModelCall(composedPrompt:submittingTo:)` with the `SubmissionTarget` of the backend of that tier (the flash container queue for the flash tier, the own queue for the own-model tier). So each summarizer call is one item on the queue of the container that runs it.
    - All five compaction paths go through `runCompaction`: the proactive check in `runAnswerWork` (`performAutoCompaction`), the tool-result yield and the ceiling stop (`RoutedSessionActorCompactionYield.swift`, `performAutoCompaction`), the overflow retry (`performAutoCompaction` in `RoutedSessionActorAnswerExecution.swift`), and the caller `compact(prompt:budget:)` (the pump runs `compactOwnModel`). Each of them runs at the pump, between two submissions, so the own-model summarizer never waits for a submission of its own session.
    - Step 2 is done: the doc of `performAutoCompaction` names no `turnLock` and no `generationGate` ("Only the pump calls it, between two submissions of this session").
    - AC1 is proven by `SummarizerSubmissionTests.aFlashSummarizerCallAndAFlashSubmissionNeverOverlap` (^1psqdm9).
    - AC2 and AC3 have no test yet. `ToolResultCompactionTests.crossingResultCompactsAndTheAnswerEnds` runs a yield compaction over a queued backend, but its summarizer is the flash tier (the flash slot resolves to the same container), not the own-model tier. No test cancels a summarizer call while it waits for its queue place.
    - Plan: add two tests to `SummarizerSubmissionTests`. AC2: a session on the flash slot (so only the own-model tier is offered) over a `LiveBackendContainer` of `ToolResultCompactionModel`; a tool result crosses the trigger; the answer ends with one own-model compaction between a `.message` and a `.continuation` submission. AC3: the AC1 setup; while the flash summarizer waits for the flash worker, `cancel()` the session; the answer throws `CancellationError`, the waiting item leaves the flash queue and never runs, and the own-model tier does not run (the `isWorkCancelled` check in `abandonCompactionIfCancelled`).
    - AC3 wording: the predicate is now `isWorkCancelled` (^3qx0mpt renamed `isTurnCancelled`). The test keys on its effect (no fall back to the next tier), not on the type of the error.
  timestamp: 2026-09-26T12:03:24.301620+00:00
- actor: claude-code
  id: 01m3etf0hj0esdajdbr1gszabx
  text: |-
    Implementation (tests only; no production change was necessary).
    - Decision: the AC2 test is in `ToolResultCompactionTests`, not in `SummarizerSubmissionTests` as the research comment planned. Reason: that suite already has the fixture (a `LiveBackendContainer` of `ToolResultCompactionModel` plus `LargeResultTool`). A copy of the fixture in the other suite would be duplicate code. `makeFixture` got a `slot` key path (default `\.standard`), and `Fixture` got the `queue` of its container.
    - Decision (design over description): AC2 is "between two submissions of an answer" (the tool-result yield stops the first submission; the pump compacts; the continuation is the second submission). AC3 keys on `isWorkCancelled` (the name after ^3qx0mpt) through its effect: `AnswerFailure.reason == .cancelled` (the reason is `.cancelled` only when `isWorkCancelled` holds) and no call of the own-model tier. It does not key on the type of `CancellationError`.
    - AC1: `SummarizerSubmissionTests.aFlashSummarizerCallAndAFlashSubmissionNeverOverlap` (from ^1psqdm9). Its set-up moved into the helper `startSummarizerBehindAFlashSubmission()`, which AC3 uses too.
    - AC2: `ToolResultCompactionTests.ownModelSummarizerBetweenTwoSubmissionsCompletes`. The session is on the flash slot, so only the own-model tier is offered. It checks one compaction with `summarizerTier == .ownModel`, submission causes `[.message, .continuation]`, the answer text, and an idle queue. The wait for the answer is bounded; on a time-out the test cancels the session, so a deadlock fails and does not hang.
    - AC3: `SummarizerSubmissionTests.aCancelWhileTheSummarizerWaitsCancelsTheAnswer`. While the flash summarizer item waits behind a flash submission of another session, `cancel()` returns `.requested`; the answer ends with `answerFailed(.cancelled)` while the other submission still holds the worker; the flash queue has 0 waiting items; the summarizer never enters the model; no compaction; the standard (own-model) log does not grow; the stream throws `CancellationError`.
    - Mutation checks (both reverted; `git diff Sources` is empty): (1) `GenerationQueue.submit` with an empty `onCancel` makes the AC3 test fail with 5 issues (the answer does not end inside the bound). (2) A summarizer body that submits again to its own queue (a self-wait) makes the AC2 test fail after the 5 s bound with `CancellationError`, and the run does not hang.
    - Step 1 (each compaction path) is covered by the research comment: all five paths go through `runCompaction`, which wraps each tier in `CancellableCompactionSummarizer`. Step 2 was already done by earlier tasks.
  timestamp: 2026-09-26T12:18:57.714091+00:00
- actor: claude-code
  id: 01m3etfpjcdcbh0ax13z1qx2xz
  text: |-
    ### implement — changed
    - evidence: 2 test files changed, no production file — Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift (new test `aCancelWhileTheSummarizerWaitsCancelsTheAnswer`, helper `startSummarizerBehindAFlashSubmission`), Tests/FoundationModelsRouterTests/ToolResultCompactionTests.swift (new test `ownModelSummarizerBetweenTwoSubmissionsCompletes`, `makeFixture(slot:)`, `Fixture.queue`). `swift build --build-tests`: no compiler warning (only the known mlx `missing creator` line). `swift test`: 1468 + 15 + 19 = 1502 passed (last green 1500, plus 2 new tests; the 2 known issues are the intended `withKnownIssue` in BoundedWaitTests and RealModelHarnessTests). Compaction, queue and cancellation suites (`--filter 'Compaction|GenerationQueue|Cancellation|SummarizerSubmission|MessageQueue|QueuedPass|SharedGenerationQueue'`, 207 + 5 + 19 tests) with `--maximum-repetitions 25 --repeat-until fail`: all passed. The 3 summarizer tests with 200 repetitions: passed. `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - next: review
  timestamp: 2026-09-26T12:19:20.268379+00:00
depends_on:
- 01M39ZNSNZGBYEY5G8R93KJN94
- 01M3CYJ4VS4VF5EEHA01PSQDM9
position_column: doing
position_ordinal: '80'
title: Run each compaction summarizer call as a queue item on the queue of its own container
---
## Why

Now the flash-tier summarizer runs under the gate of the CALLING model, not of the flash container. `performAutoCompaction` (`Session/RoutedSessionActorCompaction.swift`) builds it from `profile.flash.container.makeSession(...)` while the turn holds its own model's gate. A flash generation of another session can thus run at the same time on the flash model. This is a defect. Design: `generation-queue.md`, section 2.

With the executor-level queue, a backend made by the flash container gets the flash queue (^8csj2hw makes one queued wrapper for each backend, over the queue of its container). Thus most of the fix comes from the queue task. This task proves it and covers each compaction path.

## What to do

1. Check each compaction path: turn-start compaction, compaction between passes (tool-result boundary), ceiling-stop compaction, overflow retry, and the caller `compact(prompt:budget:)` in `RoutedSessionActorCompaction.swift`. Each summarizer call must be one queue item on the queue of the container that runs it, and must not wait while its own session holds a place on the same queue (self-deadlock).
2. Update the doc comment of `performAutoCompaction` ("The caller must already hold ``turnLock`` and a ``generationGate`` permit").

## Acceptance Criteria

- [x] A test shows the flash summarizer waits on the flash queue: a flash pass of another session and the summarizer never overlap. (Test: `SummarizerSubmissionTests.aFlashSummarizerCallAndAFlashSubmissionNeverOverlap`.)
- [x] A test shows the own-model summarizer, called between two passes of a turn, completes (no self-deadlock). (Restated by the design as "between two submissions of an answer". Test: `ToolResultCompactionTests.ownModelSummarizerBetweenTwoSubmissionsCompletes`.)
- [x] A cancel during a summarizer wait for a queue place cancels the turn (`isTurnCancelled` path). (The predicate is now `isWorkCancelled`, and the unit is the answer. Test: `SummarizerSubmissionTests.aCancelWhileTheSummarizerWaitsCancelsTheAnswer`.) #generation-queue