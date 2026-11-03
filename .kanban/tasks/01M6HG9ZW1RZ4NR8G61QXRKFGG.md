---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hhwhw31x9w01ce93mdyvtz
  text: |-
    ### implement — changed
    - evidence: 9 files. New public error SessionEndedMarkerError.sessionSuspended(ULID). New protocol property RoutedSession.isSuspended. markEnded throws that error for a suspended live session and writes nothing. Docs of markEnded, suspend() and suspendLiveSessions() updated. Tests: 1 new in SessionEndedMarkerTests, 1 new in SuspendingCloseTests. Full swift test: 2403 tests in 285 suites passed (plus 38 and 19 in the other two runs).
    - open item: a child that is suspended and then closed leaves the directory (close unregisters it). A markEnded after that closes is a recorded-session mark and still writes the marker. The card says a recorded session is not affected, so this was left as is.
    - next: review
  timestamp: 2026-11-03T20:33:53.027217+00:00
- actor: claude-code
  id: 01m6hj4ajntfvn6jy37w8j6t8a
  text: |-
    ### implement — changed
    - evidence: gap fixed. The directory keeps the ids of suspended sessions (suspendLiveSessions and unregister of a suspended session). markEnded throws sessionSuspended for them also after the close. New test: aMarkOnASuspendedThenClosedSessionWritesNothing. Full swift test: 2404 tests in 285 suites passed.
    - next: review
  timestamp: 2026-11-03T20:38:07.701726+00:00
position_column: review
position_ordinal: '80'
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