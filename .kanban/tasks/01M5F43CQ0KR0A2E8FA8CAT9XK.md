---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gak0ycjm2zqf2t1aqnrh0a
  text: |-
    Implementation landed (TDD). Discoveries:
    - The session reaches its directory through `profile.<slot handle>.sessionDirectory` (new private nonisolated `sessionDirectory` on RoutedSessionActor in RoutedSessionActorForking.swift, an exhaustive switch over `slot`).
    - `fork` registers the child (`.fork`, parent = source) right before it returns. `close()` calls `unregister(id)` first, before any wait, so a close from the session's own work (which returns at once) also leaves the live list.
    - `restoreSessionTree` registers each node in `restore(_:)` through the routed handle's directory, using the new `SessionNode.directoryLineage`: a recorded fork is `.fork` of its parentId; otherwise `agentSpawn` gives `.subagent` of spawn.parentSessionId; otherwise `.root`.
    - TDD trap: before `close()` unregistered, the restore tests passed for the WRONG reason. The closed original was still registered under the same id. I implemented close first; after that the restore tests failed for the right reason.
    - Latent hazard (not fixed, out of scope): `unregister(_ id:)` is by id. A second `close()` on a stale, already-closed instance after a restore of the same id would drop the live restored entry. An identity-checked unregister would close this gap.
  timestamp: 2026-10-21T22:51:24.492695+00:00
- actor: claude-code
  id: 01m5gak5xqa45jwafrvfbm5r97
  text: |-
    BLOCKER (needs a human decision): acceptance criterion "`restoreSession(id:)` gives a session that is in the directory, and its recorded forks are too" conflicts with two documented contracts.
    1. `restoreSession(id:)` doc: "The recorded forks under the named session are rebuilt too, and are then released. Nothing in the returned value names one."
    2. session.md 5.2 / RouterSessionDirectory: "The directory holds weak references to the live sessions, so it does not keep a closed session alive."
    Checked with a probe test (since removed). After `restoreSession(id: source.id)`, `sessions(matching: SessionQuery())` holds only the root. The forks did register during the restore, but they deallocate when `restoreSession` drops the tree, and the weak entries go with them.
    What is done: every restored node registers inside `restoreSessionTree`. Test `aRestoredForkIsInTheDirectoryAsAForkOfItsSource` proves a recorded fork is in the directory (`.fork`, parent = source) while the tree holds it.
    Options for the owner: (a) accept the restoreSessionTree-held test as meeting the criterion; (b) have the restored root keep its restored forks alive, which changes the documented `restoreSession` contract and costs a backend per fork; (c) the directory holds restored forks strongly until close, which breaks the weak-hold design. I did not pick one.
  timestamp: 2026-10-21T22:51:29.591244+00:00
- actor: claude-code
  id: 01m5gak92wrshzn7717qfkmjy1
  text: |-
    ### implement — stuck
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift (new). `swift build --build-tests` clean; `swift test --filter RouterSessionDirectoryForkRestore` 6/6 pass; full `swift test` 2015 tests pass (9 known issues, all pre-existing).
    - gap: subtask 2 and acceptance criterion 2 (recorded forks in the directory after `restoreSession(id:)`) conflict with the documented `restoreSession` release contract and the weak-hold directory. See the BLOCKER comment.
    - next: the owner picks option (a), (b) or (c); then finish or move to /review.
  timestamp: 2026-10-21T22:51:32.828558+00:00
- actor: claude-code
  id: 01m5gan3hf6xbm107baep62awp
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 7/9; acceptance criterion "recorded forks listed after restoreSession(id:)" conflicts with the documented release of forks in restoreSession and the weak-reference directory (session.md 5.2)
    - test: green per implementer — full suite 2015 passed, 9 known issues
    - commit: 18bd0e0c (partial)
    - needs a human decision: (a) accept the restoreSessionTree test, (b) restored root keeps its forks alive, (c) directory holds restored forks strongly
    - also noted: removal is by session id, so a second close() on a stale closed object could remove a live restored session with the same id
  timestamp: 2026-10-21T22:52:32.687239+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F41EWV2VJ9EBCJT36A1Y9N
position_column: review
position_ordinal: '8780'
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
- [x] Failing test first: `fork(workingDirectory:)` gives a child that is in the directory with kind `fork` and the source as parent.
- [ ] Register restored sessions from `restoreSession(id:)`, root and recorded forks, using a recording made in the same test. (BLOCKED, see comments: the root registers; the recorded forks register, but `restoreSession(id:)` releases them and the weak directory drops them)
- [x] `close()` unregisters; the closed session is gone from the query while the test still holds it.
- [x] A restored session's summary carries the facts read back by the ROUTER-1 restore card.

## Acceptance Criteria
- [x] A fork has `kind == .fork` and its source id as parent.
- [ ] `restoreSession(id:)` gives a session that is in the directory, and its recorded forks are too. (BLOCKED: root yes; forks only while a caller holds them, which `restoreSession(id:)` does not)
- [x] After `close()`, the session is not in the live query.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift`
- [x] `swift test --filter RouterSessionDirectoryForkRestore` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api