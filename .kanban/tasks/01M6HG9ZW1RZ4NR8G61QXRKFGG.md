---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: markEnded must not write an ended marker on a suspended session (audit item 5)
---
## What
Audit item 5 (2026-11-03). `RouterSessionDirectory.markEnded(_:reason:)` is not stopped by `suspend()`: after the host suspends, a child that ends by itself still gets an ended marker (it writes `index.md` through `changeRecord`), while its result mail and `completeClaimedRun` are dropped (the journal refuses `.completed` after suspend). The parent call stays an orphan, but restore skips the child because it is ended: the result is lost for good.

## Do
- A suspended live session refuses the marker: decide the shape (for example `markEnded` returns the unchanged state and does not write when the live session is suspended, with a documented typed result or error such as `SessionDirectoryError.sessionSuspended`; choose the smallest that a host can handle; the host call in Agents is `AgentRun.markEnded`).
- A recorded (not live) session is not affected.
- `close()` never sets the marker; this stays.
- Update the doc of `markEnded`, `suspend()` and `suspendLiveSessions()`.

## Acceptance Criteria
- [ ] After `suspend()`, `markEnded` on that live session writes no marker and tells the host (typed).
- [ ] Before `suspend()`, and for a recorded session, behavior is unchanged.
- [ ] A restore after suspend finds the child unended and the parent call orphaned.

## Tests
- [ ] Extend `SessionEndedMarkerTests` / `SuspendingCloseTests`; full `swift test` once.

## Workflow
- Use `/tdd`. Queue: after `cancelForeground`, before the SessionEnd/HookSession card. #subagents