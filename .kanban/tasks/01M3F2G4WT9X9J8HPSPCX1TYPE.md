---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
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

- [ ] The cause is found and written on this task.
- [ ] If it is a production race: a fix and a regression test. If it is test timing: the test waits on a real signal, not on time.
- [ ] The stress above gives 0 failures of this test over 3 rounds. #test-flake