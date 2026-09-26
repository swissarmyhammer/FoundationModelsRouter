---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3f39gjjb96qqt3tkaq34ecc
  text: |-
    Research (implement). Cause found by reading the code path. It is a production race, not test timing.

    - The caller-task route: `awaitAnswer(of:)` (RoutedSessionActorGeneration.swift) has `onCancel { message.answer.requestCancel(); Task { await self.cancel(message: message.id) } }`. `answerTask.cancel()` runs the handler synchronously, so the mark (`PumpAnswer.cancelRequested`, an atomic) is stored before `release.signal()`. But the second half, `cancel(message:)` -> `requestCancelOfRunningWork()` -> `cancelRequestedWorkId = workId`, runs later in an unstructured task that must hop onto the session actor.
    - The retry decision: `runCancellableModelCall` checks `isWorkCancelled` before it starts the retry's model call. `isWorkCancelled` reads only `Task.isCancelled` (the pump task, never cancelled by a caller) and `cancelRequestedWorkId`. It does not read the mark of the messages the work delivers.
    - So under load: the tool throws the overflow, the pump gets the actor first, compacts (no-op), reads `isWorkCancelled == false`, and starts the retry. The `cancel(message:)` hop comes after that and cancels a model call that already entered the model. This matches the failure (`.modelReenteredAfterCancellation`).
    - The `routerAPI` route does not have the window: the test awaits `session.cancel()`, which sets `cancelRequestedWorkId` on the actor before `release.signal()`.

    Plan: `isWorkCancelled` also reads the cancel marks of `deliveredMessages` (atomic loads, no lock, no suspension). A delivered message with a mark is exactly the case where `cancel(message:)` would call `requestCancelOfRunningWork()` for this work, so the result is the same, only earlier. `cancelRequestedWorkId` keeps its one read site. Test: set only the mark of the delivered message (the first half of a caller cancel) while the tool holds the model, and never run `cancel(message:)`. This forces the order "mark before retry, withdraw never" with no timing.

    Baseline stress 1 at HEAD: 12 processes x 30 repetitions of the ^zr22hpd filter, load 11 to 16: 0 failures (12 x 109 tests passed). The load was lower than the 27 to 51 of the first report. A second run with 24 x 60 is in progress.
  timestamp: 2026-09-26T14:53:14.706576+00:00
- actor: claude-code
  id: 01m3f3f97entaam0rbkmej68kx
  text: |-
    Reproduced at HEAD c75de40 (before the fix), baseline stress 2: 24 `swiftpm-testing-helper` processes x `--repetitions 60`, the ^zr22hpd filter, load average 6.8 to 28.4. Result: 1 failure of `cancellationSurvivesIntoTheOverflowRetry` route `callerTask` (process 18, exit 1), with the same two issues as the report (`.modelReenteredAfterCancellation` at AnswerCancellationEntryPointTests.swift:338, and `entered == ["overflow-then-cancel"]` at :341). 3 other processes stopped with exit 134, `_ContiguousArrayStorage deallocated with non-zero retain count 2`: that is the known SDK crash ^vg6bmq6, not this task.

    RED: new test `theCancelMarkAloneStopsTheOverflowRetry` ("a caller cancel whose mark is set but whose withdraw has not come stops the overflow retry"). It sets only `PumpAnswer.requestCancel()` on the delivered message (from `RoutedSessionActor.deliveredMessages`) while the tool holds the model, then lets the tool throw the overflow. It never calls `cancel(message:)`. At HEAD it failed with the same signature: `expected error of type CancellationError, but ".modelReenteredAfterCancellation" of type ProbeError was thrown instead`. The test forces the order with no timing.

    GREEN: `isWorkCancelled` (RoutedSessionActorAnswerExecution.swift) now also returns true when a message of `deliveredMessages` has its cancel mark. Both tests pass. `cancelRequestedWorkId` keeps its one read site. The read is an atomic load on the actor: no lock, no new suspension point.

    Test change: the hook of `cancellationSurvivesIntoTheOverflowRetry` moved into the shared fixture `overflowAfterRelease(_:prompt:insideTool:release:)` (AnswerCancellationFixtures.swift), so the two tests do not copy it.
  timestamp: 2026-09-26T14:56:23.790189+00:00
- actor: claude-code
  id: 01m3f427h2v6m0fv91xtap8pbk
  text: |-
    Stress with the fix, 3 rounds of 24 processes x `--repetitions 60`, the ^zr22hpd filter: 0 issues of `cancellationSurvivesIntoTheOverflowRetry` and 0 of `theCancelMarkAloneStopsTheOverflowRetry` in each round. Loads: 11.7 to 28.0, 12.6 to 33.5, 13.4 to 31.1. Processes with all repetitions done: 20, 24, 18. The rest stopped on ^vg6bmq6 (exit 134, and 2 x exit 139 with FoundationModels frames; data added on ^vg6bmq6).

    Full suite, 3 plain runs of `swift test --skip-build`: 1487 + 17 + 19 = 1523 passed (1522 + the new test), 0 warnings in the build. One earlier plain run, just after the stress ended, had 1 issue in `cancellingAStreamingAnswerFinishesTheStreamWithCancellationError` (the first streamed chunk did not reach the consumer inside the bound, before the test cancels). No mark is set on that path before the cancel, so it is not from this change. Filed as ^7w145zc.

    Not done here, filed as ^5mnw172: a caller cancel in the short window before `awaitAnswer(of:)` installs its handler sets only `Task.isCancelled` of the caller, and the mark comes when the handler is installed. No test can force that order, so this task did not change it.

    Design notes: no lock and no new suspension point. The read of the mark is an atomic load (`PumpAnswer.cancelRequested`, `Atomic<Bool>`) on the session actor. `cancelRequestedWorkId` keeps its one read site. No new name uses "turn".

    ### implement — changed
    - evidence: cause = `isWorkCancelled` did not read the caller's cancel mark, and the withdraw hop came after the pump's retry decision. Files: Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift, Sources/FoundationModelsRouter/Session/SessionMessage.swift (doc), Tests/FoundationModelsRouterTests/AnswerCancellationEntryPointTests.swift, Tests/FoundationModelsRouterTests/AnswerCancellationFixtures.swift. Stress: HEAD 1 failure in 24x60; fix 0 in 3 x 24x60. Suite 1487 + 17 + 19 green.
    - next: /review
  timestamp: 2026-09-26T15:06:44.642470+00:00
position_column: doing
position_ordinal: '80'
title: Find why cancellationSurvivesIntoTheOverflowRetry (callerTask route) re-enters the model under parallel stress
---
## What

Under parallel stress at HEAD f04e07d (plus the test-only changes of ^zr22hpd), the test `AnswerCancellationTests.cancellationSurvivesIntoTheOverflowRetry(route:)`, display name "a cancellation landing during a failed attempt stops the overflow retry from re-running the model", failed once with the route `callerTask` ("the caller's own Task"):

- `AnswerCancellationEntryPointTests.swift:338`: `expected error of type CancellationError, but ".modelReenteredAfterCancellation" of type ProbeError was thrown instead`.
- `AnswerCancellationEntryPointTests.swift:341`: `await fixture.observer.entered == ["overflow-then-cancel"]` failed.

So the overflow retry ran the model again after the caller task was cancelled.

## Measurement (2026-09-26)

- Found in 1 of 12 processes: 12 `swiftpm-testing-helper` processes, `--repetitions 30`, filter `FoundationModelsRouterTests\.(GenerationQueueTests|GenerationQueueSubmissionTests|GenerationQueueWorkerTests|GenerationQueueWorkerTaskTests|SharedGenerationQueueContentionTests|QueuedPassStallWatchTests|AnswerCancellationTests|NestedGenerationReentryTests|PooledResidencyTests|ForkConcurrencyTests|RecordingLanguageModelTests)/`, load average 27 to 51 (the command is in the memory note `stub-backend-producer-race.md`).
- Not found: the test alone, 16 processes x 2000 repetitions, load 11 to 17. It needs the mixed load.

## Next

- The test cancels the caller task (`answerTask.cancel()`) and at once signals `release`, so the tool throws the overflow. Find if the cancel of the caller reaches the answer (`PumpAnswer.requestCancel()`, then the withdraw on the session actor) before the pump decides to run the retry. If the retry reads only state that the async withdraw sets, the cancel can come too late: that is a production race, not a test timing problem.
- Compare with the `routerAPI` route, which calls `session.cancel()` and awaits it before `release.signal()`.

## Acceptance

- [x] The cause is found and written on this task.
  - Production race. The caller cancel sets the mark at once, but `cancel(message:)` (which sets `cancelRequestedWorkId`) runs in an unstructured task that must get the session actor. The pump got the actor first after the overflow, read `isWorkCancelled == false` (it did not read the mark), and started the retry. See the comments.
- [x] If it is a production race: a fix and a regression test. If it is test timing: the test waits on a real signal, not on time.
  - Fix: `isWorkCancelled` (RoutedSessionActorAnswerExecution.swift) also reads the cancel marks of `deliveredMessages`. Regression test: `AnswerCancellationTests.theCancelMarkAloneStopsTheOverflowRetry` (AnswerCancellationEntryPointTests.swift). It sets only the mark and never sends the withdraw, so it forces the order with no timing. It failed at HEAD with `.modelReenteredAfterCancellation`, and passes with the fix.
- [x] The stress above gives 0 failures of this test over 3 rounds.
  - Command: 24 `swiftpm-testing-helper` processes, `--test-bundle-path <copy of .build/out/Products/Debug>/FoundationModelsRouterTests.xctest/Contents/MacOS/FoundationModelsRouterTests --testing-library swift-testing --repetitions 60 --filter` with the filter above (twice the processes and repetitions of the first report). At HEAD before the fix: 1 failure of this test (route `callerTask`), load 6.8 to 28.4. With the fix, 3 rounds: 0 failures of this test and 0 failures of the new test. Load 11.7 to 28.0, 12.6 to 33.5, and 13.4 to 31.1. Processes that finished all repetitions: 20, 24 and 18 of 24. The other processes stopped on the SDK crash ^vg6bmq6 (exit 134, and exit 139 twice, in FoundationModels frames), which is known and separate. #test-flake