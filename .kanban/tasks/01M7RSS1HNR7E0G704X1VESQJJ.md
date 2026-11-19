---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
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

- [ ] A live fork, then a restore of its source by id: the live fork keeps its hook entry and its directory entry, gets no extra `SessionStart`/`SessionEnd`, and closes with one `SessionEnd`.
- [ ] Nothing live, a restore of a root by id: hooks fire only for the root.

#d205