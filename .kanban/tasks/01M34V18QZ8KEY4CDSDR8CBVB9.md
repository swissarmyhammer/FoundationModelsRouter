---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34wwv8s68wygzgv4mc6mppr
  text: |-
    ### research
    - Sites found: `Session/RejectedToolCallRetry.swift:23-26` (the constant), `:79-88` (`logRetry(sessionID:retriesLeft:)`), `Session/RoutedSessionActorTurnExecution.swift:281, :318, :330, :341, :399, :411, :425, :436, :439-445, :462`, `Tests/.../AutoCompactionTests.swift:12` (a doc link that names the `rejectedCallRetriesLeft:` label), `Tests/.../RejectedToolCallRetryTests.swift:13-14, :31-33, :87-102`.
    - The test fixture `RejectingLanguageModel(rejectionCount:)` already rejects the first N calls and then answers. The new test needs no new fixture.
    - No test exists for a cancellation during a rejected-call retry. The cancellation test that stays is `TurnCancellationTests.swift:1404`: a cancellation that lands during a failed attempt stops the retry before the model runs again. A rejected-call retry runs through the same `runTurnAttempt` path, so the same guard applies.
    - The log line needs the retry ordinal. The card names it. A parameter `rejectedCallRetries` (how many rejected-call retries this turn has run) replaces `rejectedCallRetriesLeft`. It is not a bound.
  timestamp: 2026-09-22T15:49:03.897478+00:00
- actor: claude-code
  id: 01m34x6djqy6cw60f7y3wdjzc8
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Session/RejectedToolCallRetry.swift (the `limit` constant is deleted; `logRetry(sessionID:ordinal:)` writes "retry N of this turn"), Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift (`rejectedCallRetriesLeft` is deleted; `rejectedCallRetries` carries the ordinal, with a default of 0 for the first attempt; a `RejectedToolCallError` always retries; the doc says the retries have no count), Tests/FoundationModelsRouterTests/RejectedToolCallRetryTests.swift (`retriesStopAtTheBound` is replaced by `retriesContinueUntilTheModelWritesAValidCall`: 5 rejections, then the answer; the last retry prompt holds 5 tool errors), Tests/FoundationModelsRouterTests/AutoCompactionTests.swift (a doc link names the new label).
    - acceptance: `rg 'rejectedCallRetriesLeft|RejectedToolCallRetry\.limit'` finds nothing (exit 1).
    - build: `swift build --build-tests` complete; `swift build --package-path IntegrationTests --build-tests` complete.
    - tests: `swift test --skip-build --filter RejectedToolCallRetryTests`: 2 tests in 1 suite passed.
    - next: run the test skill, then commit, then review.
  timestamp: 2026-09-22T15:54:17.559364+00:00
- actor: claude-code
  id: 01m34x96e69c62m216bd4ay1da
  text: |-
    ### test — green
    - evidence: `swift test` — 1349 tests in 145 suites passed, plus 1 test and 83 tests in the other targets; 0 failures. The 2 known issues are pre-existing `withKnownIssue` marks in RealModelHarnessTests.swift and BoundedWaitTests.swift, files this task did not touch. `swift build --build-tests`: zero code warnings. `swift build --package-path IntegrationTests --build-tests`: complete. `swift-format lint` under the seven idioms-swift rules: 0 findings on the 4 changed files.
    - next: commit, then review.
  timestamp: 2026-09-22T15:55:48.550882+00:00
position_column: doing
position_ordinal: '80'
title: Delete RejectedToolCallRetry.limit; a rejected tool call retries until the model writes a valid call
---
## Decision (from the owner, 2026-09-22)

`RejectedToolCallRetry.limit` (2, `Session/RejectedToolCallRetry.swift:26`) is an invented count and must go. A rejected tool call goes back to the model as a tool error, and the attempt runs again, until the model writes a call the parser accepts, the caller cancels, or the context fills.

## Why

- The count came with commit 3424179 (2026-09-21) with no reason for 2.
- The exits that matter exist: the caller's cancel, and the context window (each retry appends the rejection note to the prompt, so a model that never corrects itself reaches the overflow path). A count of 2 ends the turn early and silently; the caller sees a failed turn and has to guess.

## Sites

- `RejectedToolCallRetry.swift:22-26`: the constant and its doc. `:65-77` `prompt(retrying:)`: keep; each retry's prompt carries the earlier tool errors.
- `RoutedSessionActorTurnExecution.swift:281`: `rejectedCallRetriesLeft: RejectedToolCallRetry.limit`. `:334-343, :427-445`: the `rejectedCallRetriesLeft` parameter threaded through `runTurnAttempt` and `recoverFailedAttempt`, and the `rejectedCallRetriesLeft > 0` guard.
- `RejectedToolCallRetry.logRetry(sessionID:retriesLeft:)`: the log line names retries left.
- Tests: `RejectedToolCallRetryTests` cases that assert the third rejection ends the turn.

## Do this

1. Delete the constant and the `rejectedCallRetriesLeft` parameter. The guard becomes: a `RejectedToolCallError` always retries.
2. The log line names the retry ordinal (this is retry N of this turn), not a count left.
3. Replace the test that asserts the cut-off with one where a scripted model writes a rejected call 5 times and a valid one the sixth time: the turn succeeds after 5 retries. Keep the test that a cancellation during a retry ends the turn.
4. Do not add a count anywhere else.

## Acceptance

- `rg 'rejectedCallRetriesLeft|RejectedToolCallRetry\.limit'` finds nothing.
- The tests above pass. All tests pass. #compaction #limits