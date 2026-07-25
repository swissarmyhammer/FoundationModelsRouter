---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Make a compaction fold observe cancellation, so a client stop lands during a long fold too
---
## What

`cancelCurrentTurn()` (task ^0r7mxew) cancels the turn's **model call**. A turn that is *folding its own transcript* has no model call outstanding, so a stop landing in that window is remembered against the turn and honored by its next model call — the fold itself runs to completion first.

That window is not small. A proactive auto-compaction fold (`autoCompactionBudget` reached) runs the whole `Compactor` pipeline and, when the deterministic stages cannot land it, a full model-assisted `Summarization` generation on the flash slot. A user pressing stop during it currently waits out a summarization they asked to abandon. `compact(prompt:budget:)`'s caller-driven fold has the same shape, though there the caller owns the enclosing `Task` and can cancel it.

`RoutedSession.cancelCurrentTurn()`'s doc states the limitation outright today ("What that does *not* do is interrupt the fold already running"), and `plan.md` says the same, so this is a documented gap rather than a silent one.

## Why it was left out of ^0r7mxew

Two reasons, both worth knowing before starting:

1. **Scope.** That task's contract was cancelling the `Task` that owns `body(composedPrompt)`. A fold's summarizer call is not that.
2. **An event-loss hazard sits in the obvious implementation.** `runTurn` calls `try await performAutoCompaction(...)` *before* `runTurnAttempt`, and the turn's drained `pendingEvents` are re-queued only inside `runTurnAttempt` (via `finishTurnAndRequeueIfUnattached`). So making `performAutoCompaction`/`fold` throw `CancellationError` mid-fold would drop the events this turn drained from the outbox — silently destroying exactly the state ^0r7mxew was careful to preserve. `performAutoCompaction`'s doc currently promises it throws nothing from summarization, and `runTurn` relies on that.

## Work

- Have the fold path observe cancellation — at minimum before its model-assisted `Summarization` stage, which is the expensive part — for both `cancelCurrentTurn()` (`cancelRequestedTurnId`) and the caller's own `Task` (`Task.isCancelled`).
- Decide what a turn cancelled mid-fold leaves behind, and make it as well-defined as a turn cancelled mid-model-call already is:
  - the drained `pendingEvents` must be re-queued, not lost (see hazard 2 above — the requeue currently lives in the wrong place for this);
  - the transcript must not gain a half-applied fold (`fold` swaps `backend` and bumps `persistedEntryCount` only after appending the fold's new entries — check that an abandoned fold leaves the session exactly as it was);
  - whether the caller sees `CancellationError` from the fold, and whether a *proactive* fold's cancellation still records a turn trace at all (today a throw from `performAutoCompaction` escapes `runTurnAttempt`'s recording bracket entirely).
- Deterministic-stage-only folds are fast; do not add cancellation checks that make a cheap fold slower or its result nondeterministic.
- Update `RoutedSession.cancelCurrentTurn()`'s doc and `plan.md`'s turn-loop bullet, both of which currently state the opposite.

## Acceptance Criteria

- [ ] A cancellation landing during a fold's model-assisted stage stops that fold instead of waiting it out, by both cancellation routes.
- [ ] A turn cancelled mid-fold re-queues its drained outbox events rather than destroying them.
- [ ] A turn cancelled mid-fold leaves the transcript and `backend` exactly as they were, never a half-applied fold.
- [ ] What the caller observes is documented and matches the mid-model-call case.
- [ ] Docs (`cancelCurrentTurn()`, `plan.md`) no longer state the old limitation.

## Tests

- [ ] Cancelling a turn parked inside a proactive fold's summarizer call unwinds it, for `cancelCurrentTurn()` and for the caller's own `Task`.
- [ ] That turn's drained outbox events are still pending afterwards.
- [ ] The session's transcript/entry count is unchanged by the abandoned fold, and a later turn on the session succeeds.
- [ ] A deterministic-only fold with no cancellation outstanding behaves exactly as it does today (regression).
