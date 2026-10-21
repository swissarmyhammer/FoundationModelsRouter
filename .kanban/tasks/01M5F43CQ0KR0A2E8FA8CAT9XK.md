---
assignees:
- claude-code
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F41EWV2VJ9EBCJT36A1Y9N
position_column: todo
position_ordinal: '9380'
title: 'ROUTER-3: Forks and restored sessions register, and close() leaves the live list'
---
## Goal
The other vend points register too: a fork, a restored root and each restored fork; and a closed session leaves the live list even while a host still holds it.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory ("new, restored, forked, subagent")
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md sections 2 and 5.2 (test: "A closed session leaves the live list")

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift`, `fork(workingDirectory:)`: register the child with kind `fork` and parent id = the source session (the source reaches the directory through its `profile`'s `RoutedModel` link from the previous card).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift`, `restoreSessionTree`: register the restored root (kind from its sidecar: `agentSpawn` gives `subagent`, else `root`) and each restored fork (`fork`, parent = its source).
- `close()` (in `RoutedSessionActorForking.swift`) calls the directory's `unregister`.

## Subtasks
- [ ] Failing test first: `fork(workingDirectory:)` gives a child that is in the directory with kind `fork` and the source as parent.
- [ ] Register restored sessions from `restoreSession(id:)`, root and recorded forks, using a recording made in the same test.
- [ ] `close()` unregisters; the closed session is gone from the query while the test still holds it.
- [ ] A restored session's summary carries the facts read back by the ROUTER-1 restore card.

## Acceptance Criteria
- [ ] A fork has `kind == .fork` and its source id as parent.
- [ ] `restoreSession(id:)` gives a session that is in the directory, and its recorded forks are too.
- [ ] After `close()`, the session is not in the live query.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift`
- [ ] `swift test --filter RouterSessionDirectoryForkRestore` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api