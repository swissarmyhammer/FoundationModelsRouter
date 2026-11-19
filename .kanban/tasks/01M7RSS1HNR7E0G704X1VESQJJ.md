---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rt7jk93q8thbpg26e5kwr2
  text: 'Research: restoreSession(id:) with a root id calls restoreSessionTree(withForks: true); each fork gets a session, hooks (restoredHooks) and a directory registration, and the restore then drops it (release ends hooks with .released). The only production caller of restoreSessionTree is restoreSession. Rule chosen: a restore of a root by id restores the root alone (withForks: false). It makes, registers and hooks no fork session. With switchingModel, each recorded fork under the root that is not live in the router of this handle (no directory entry, or a suspended one) moves on disk: one modelChanged event and the slot, model and context in its index.md. A live fork keeps its model; the host moves it by its own restore. RED (one run, filter FoundationModelsRouterTests.(HookLineageTests|ModelSwitchRestoreTests), 51 tests): 7 new tests fail at their expectations (directory entry replaced, sub-agent key lost, extra events for the live fork, end reasons not [.completed], fork events with nothing live, live fork index.md moved, suspended fork directory entry replaced). The guard aSuspendedForkMovesWithTheRoot passes before the fix by design (kept behavior).'
  timestamp: 2026-11-19T02:30:05.673648+00:00
- actor: claude-code
  id: 01m7rtf53tfrkk4ckq02gd762h
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Recording/SessionRestoration.swift (restoreSession calls restoreSessionTree with withForks: false; new forksMovingWithRoot replaces isRecordedFork; docs of the forks paragraph, userPresence, hookSessionKey, claimingRuns, switchingModel), Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift (new moveRecordedForks(_:) and isLive(_:); recordModelChange and appendRestoreEvent lifted to fileprivate static so the disk move and the rebuild share them; SessionNode.forks), Tests/FoundationModelsRouterTests/HookLineageTests.swift (5 tests), Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift (3 tests). RED: 7 of the 8 new tests failed at their expectations before the fix; aSuspendedForkMovesWithTheRoot guards kept behavior and passed before by design. GREEN: filter FoundationModelsRouterTests.(HookLineageTests|ModelSwitchRestoreTests) 51 tests passed. Full swift test once: 3056 tests in 349 suites passed (plus 49 and 19), exit 0, no compiler warnings (only the known mlx missing-creator line). Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full.txt
    - behavior change to note: a root restore by id no longer claims runs of forks under the root (runNotClaimable); a host claims a fork run by a restore of that fork by its id. restoreSessionTree(withForks: true) is unchanged (only tests call it).
    - next: /review
  timestamp: 2026-11-19T02:34:14.010159+00:00
position_column: doing
position_ordinal: '80'
title: A restore of a root session by id must not make a second instance of a live recorded fork
---
## Problem

`RoutedModel.restoreSession(id:)` with the id of a ROOT session restores the root and each recorded fork under it, and then releases the forks (`restoreSessionTree(root:)` with `withForks: true`, `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift`). Since D205 a fork is a top-level session, so a fork can be live in the same router while a host restores its source by id (for example: the user has the fork open in a tab and opens the recorded source from Recent).

Then the restore makes a second instance of the live fork:
- `restoredHooks(for:on:)` (`Recording/SessionTreeRestoration.swift`) makes a second `SessionHooks` for the id of the live fork. `start()` replaces `openSessions[forkID]` and posts a `SessionStart(.resumed)` for it. The release runs `end(reason: .released)`, which removes `openSessions[forkID]` of the LIVE fork and posts a `SessionEnd(.released)` for it.
- `register(_:kind:parentID:)` replaces the live fork in the session directory with the second instance.

When nothing is live, the dispatcher also gets a `SessionStart` and a `SessionEnd(.released)` for each released fork that no caller opened.

^3hxcxee fixed the same cause for a restore by a FORK id (`withForks: false`: the fork alone, its hook parent from the live source). The root path keeps the documented rule that the forks move with the root under `switchingModel`.

## Change

Decide and implement: a root restore by id restores no fork that is live in this router (or restores the root alone, and moves the forks by another way under `switchingModel`), and it fires no hook for a fork that it does not return. Update the doc of `restoreSession(id:)` (the forks paragraph and `switchingModel`).

## Tests

- [x] A live fork, then a restore of its source by id: the live fork keeps its hook entry and its directory entry, gets no extra `SessionStart`/`SessionEnd`, and closes with one `SessionEnd`.
- [x] Nothing live, a restore of a root by id: hooks fire only for the root.

#d205