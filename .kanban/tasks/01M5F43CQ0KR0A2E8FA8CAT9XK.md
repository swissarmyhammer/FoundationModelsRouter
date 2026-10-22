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
- actor: claude-code
  id: 01m5hxxh64jsz9g0kzvsw5xyct
  text: 'DECISION (user, 2026-10-22): option (a). `restoreSession(id:)` keeps its documented contract: it releases the recorded forks, and the directory stays weak. `restoreSessionTree(root:)` is the way to get live, listed forks; `aRestoredForkIsInTheDirectoryAsAForkOfItsSource` covers it. Subtask 2 and acceptance criterion 2 were rewritten to match and checked. Next: /review on 18bd0e0c.'
  timestamp: 2026-10-22T13:48:26.180796+00:00
- actor: claude-code
  id: 01m5hy7v7bhgwrn3exxtz8vn7r
  text: |-
    ### review — findings
    - evidence: review sha 18bd0e0c~1..18bd0e0c — 2 findings (2 confirmed, 1 refuted): Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift:34 (reuse/reuse), Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift:144 (completeness/inverse-operation-coverage)
    - next: implement the two checklist items in the 2026-10-22 08:48 Review Findings section; task stays in review
  timestamp: 2026-10-22T13:54:04.139063+00:00
- actor: claude-code
  id: 01m5hybwzbef0my2dj1m5dxezj
  text: 'Picked up the 2026-10-22 08:48 Review Findings. Research: (1) `makeSession` DOES register roots — `RoutedLLM.swift` calls `sessionDirectory?.register(` since 522b7c6c (an ancestor of HEAD), so the finding''s premise "root sessions are never registered" is wrong, but its fix (assert listed before close) still stands and is applied. (2) The four summary helpers: Event/Registration have a `Fixture.registeredSummary(of session:)` over `directory.summary(of:)`; ForkRestore has a static `registeredSummary(of:in:)`; Recorded has `recordedSummary(of:in:)` over `sessions(matching: SessionQuery(includesRecorded: true))`. One shared helper covers all four: find the id in `sessions(matching: query)`, query defaulting to the live `SessionQuery()`. The live path of `summary(of:)` stays covered by RouterSessionDirectoryQueryTests and LauncherTests.'
  timestamp: 2026-10-22T13:56:17.003144+00:00
- actor: claude-code
  id: 01m5hyk6b3qz1fkm6sy74yny1e
  text: 'Findings fixed. (1) reuse/reuse: new `Tests/FoundationModelsRouterTests/Helpers/SessionDirectorySummaries.swift` — `SessionDirectorySummaries.summary(of:in:matching:)` finds the id in `sessions(matching: query)` (query defaults to the live `SessionQuery()`). The four copies are deleted: ForkRestore''s static `registeredSummary`, the `Fixture.registeredSummary` of Event and Registration, and Recorded''s `recordedSummary` (its callers pass `SessionQuery(includesRecorded: true)`). (2) inverse-operation-coverage: `aClosedSessionLeavesTheLiveList` now reads the live query before and after `close()` and expects `[session.id]` before and empty after. Mutation check: with `sessionDirectory?.unregister(id)` removed from `close()`, the test failed only on `afterClose.isEmpty` (the before-close listing held); the line is restored and `git diff -- Sources` is empty. Tool note: the sah `edit file` `replace_all: true` replaced only one occurrence per call here, so each identical call site was edited one at a time.'
  timestamp: 2026-10-22T14:00:15.971034+00:00
- actor: claude-code
  id: 01m5hyk9h7aepxs0mh9t35k91q
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterTests/Helpers/SessionDirectorySummaries.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift, RouterSessionDirectoryEventTests.swift, RouterSessionDirectoryRegistrationTests.swift, RouterSessionDirectoryRecordedTests.swift. `swift build --build-tests` complete (exit 0); `swift test --filter RouterSessionDirectory` 72 tests in 7 suites passed. Both runs print one SwiftPM build-graph warning "missing creator for mutated node: .build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS" — from the mlx-swift bundle, not from a changed file. Both Review Findings checked.
    - next: /review
  timestamp: 2026-10-22T14:00:19.239372+00:00
- actor: claude-code
  id: 01m5hyrfrq7m81e20rhp534dj6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a444cad6) — 0 findings (0 confirmed, 0 refuted; 7 files attempted, 5 reviewed, 2 .kanban files excluded by .reviewignore). Both items in the 2026-10-22 08:48 Review Findings are checked.
    - next: none; task moved to done
  timestamp: 2026-10-22T14:03:09.463993+00:00
- actor: claude-code
  id: 01m5hyrw858fsgjj9dxjz60b19
  text: |-
    ### finish iteration 2 — clean
    - decision: option (a), restoreSessionTree gives live forks
    - implement: changed — shared SessionDirectorySummaries helper; close() test asserts listed before close
    - test: green — swift test, 2081 passed, 9 known issues
    - commit: a444cad6
    - review: clean — 0 findings, 2/2 prior checked; card in done
  timestamp: 2026-10-22T14:03:22.245632+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F41EWV2VJ9EBCJT36A1Y9N
position_column: done
position_ordinal: ffffffffac80
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
- [x] Register restored sessions: `restoreSession(id:)` registers the root; `restoreSessionTree(root:)` registers the root and each recorded fork, using a recording made in the same test. (Decision 2026-10-22, option a: `restoreSession(id:)` releases recorded forks and the directory stays weak; `restoreSessionTree` is the way to get live forks.)
- [x] `close()` unregisters; the closed session is gone from the query while the test still holds it.
- [x] A restored session's summary carries the facts read back by the ROUTER-1 restore card.

## Acceptance Criteria
- [x] A fork has `kind == .fork` and its source id as parent.
- [x] `restoreSession(id:)` gives a session that is in the directory; `restoreSessionTree(root:)` gives a root and recorded forks that are in the directory while the tree holds them.
- [x] After `close()`, the session is not in the live query.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift`
- [x] `swift test --filter RouterSessionDirectoryForkRestore` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api

## Review Findings (2026-10-22 08:48)

> Scope: `review sha 18bd0e0c~1..18bd0e0c` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift:34` `reuse/reuse` — The `registeredSummary` helper is a near-duplicate (91% match) of similar functions in RouterSessionDirectoryEventTests, RouterSessionDirectoryRecordedTests, and RouterSessionDirectoryRegistrationTests. Defining the same function in multiple test files duplicates the implementation instead of reusing it. Extract the `registeredSummary` function to a shared test helper module or file so all test files can import and reuse it.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryForkRestoreTests.swift:144` `completeness/inverse-operation-coverage` — The test unregisters root sessions created via `makeSession` by calling `close()`, but root sessions are never registered. The change registers sessions in `performFork` (line 280) and `restoreSessionTree` (line 341) but modifies `close()` to unregister all sessions (line 416), including root sessions that were never registered. The test does not verify the session was registered before `close()` — it only checks the directory is empty after close, which is trivially true if the session was never registered. Modify the test to create a fork or restored session (which are registered by this change) before testing `close()`; or add a preceding assertion that the session is registered before `close()` to verify the round-trip.
