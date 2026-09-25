---
assignees:
- claude-code
depends_on:
- 01M3CYJ4VS4VF5EEHA01PSQDM9
position_column: todo
position_ordinal: '9180'
title: Read and fork a session from its settled transcript, with no wait on turnLock
---
## Why

In the work-queue model no caller waits on a lock (user decision 2026-09-25, "not with a lock"). Now `RoutedSession.transcript` and `fork(workingDirectory:)` wait on `turnLock` while a request runs, and a fork from a tool of the same session throws `SessionReentryError.forkDuringSameSessionTurn`. The user wants the self-call errors to go. Design: `generation-queue.md`, sections 5.6 and 5.8.

The backend transcript changes on the SDK task while a submission runs (see the memory note `stub-backend-producer-race`). So a read must not copy the live backend transcript at a random time. It reads a settled copy that the session actor keeps.

## What to do

1. Add a settled transcript to `RoutedSessionActor`: the entries as of the last settled point. Update it at the end of each submission (success or failure, after the recording diff), and at each tool-result boundary (`noteToolResult(_:)` already reads `backend.transcriptEntries()` there).
2. `transcript` returns the settled transcript at once, from any task. Remove the `turnLock` wait and the `isInsideOwnTurnToolCall` bypass for reads.
3. `fork(workingDirectory:)` seeds the child from the settled transcript, at once. When the settled transcript ends in a round of tool calls with no output, remove those calls (the rule of `InFlightTranscript.removingUnansweredCalls`), so the child starts from a valid transcript. Remove `SessionReentryError.forkDuringSameSessionTurn`.
4. Update the doc comments of `transcript`, `fork(workingDirectory:)` and `SessionReentryError`.

## Acceptance Criteria

- [ ] A test: a transcript read from another task while a submission runs returns at once, with the entries of the last settled point.
- [ ] A test: a tool of a session forks its own session during the submission; the fork succeeds, and the child transcript has no tool call without an output.
- [ ] A test: a background body forks its own session while a submission runs; it does not wait for the submission (replaces `aBackgroundBodyThatForksItsOwnSessionWaitsForTheTurnToEnd`).
- [ ] `forkDuringSameSessionTurn` is gone from `Sources`.
- [ ] A parallel stress run (the `swiftpm-testing-helper` command of the memory note `stub-backend-producer-race`, 8 processes, 100 repetitions) of the new tests shows no crash that HEAD does not also show (^vg6bmq6).
- [ ] Full `swift test` green, 0 new warnings. #generation-queue