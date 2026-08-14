---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: cancelCurrentTurn() cannot stop a respond() that is draining the run plane
---
Found while landing `^nmpejc5` (`respond(to:)` self-drains the run plane).

## What is true today

`RoutedSessionActor.respond(to:maxTokens:)` now waits, between turns, for every parked run to settle (`settleParkedRuns()`), bounded by `ToolContext.waitSecondsCeiling` per run.

That wait sits **between** turns, so no turn is in flight while it runs:

- `RoutedSession.cancelCurrentTurn()` reads `currentTurnId`, finds `nil`, and reports `.noTurnInFlight`. It cancels nothing.
- `SessionMailbox.wait(completionToken:seconds:)` suspends on a `CheckedContinuation<WaitOutcome, Never>` and ignores task cancellation by design, so cancelling the caller's own task does not end the wait either.

The drain does check both routes **between rounds** (`cancelRequestCount` and `Task.isCancelled`), so a cancellation that lands while a turn is running is honored. A cancellation that lands *inside* a drain wait is not observed until that run settles, its ceiling elapses, or `close()`'s sweep resumes the waiter.

## Why it matters

A caller that starts a long backgrounded job and then wants out has no surface that ends the call. `close()` does end it (the sweep resumes every waiter), but closing the session is a bigger hammer than cancelling one call.

## What a fix probably needs

- A cancellation route that reaches a waiter of the run plane — either `cancelCurrentTurn()` reporting on (and interrupting) a draining call, or a cancellation-aware `SessionMailbox.wait`, or the drain racing each wait against a cancellation signal the way `DetachingTool.raceSettlement(of:deadlineNanoseconds:)` races a deadline.
- A decision on what a cancelled drain returns: the last turn's answer, or a thrown `CancellationError`.
- A test that cancels a call parked in its drain and observes it end.

#eventplan
