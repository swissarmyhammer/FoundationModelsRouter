---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
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