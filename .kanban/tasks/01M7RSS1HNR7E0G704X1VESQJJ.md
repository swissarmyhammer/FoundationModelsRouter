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
- actor: claude-code
  id: 01m7rtqbvawe99stex2zx1k7tn
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 2 engine findings (2 confirmed, 0 refuted) at Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:862 and :866. Orchestrator checks: 4 more findings at SessionTreeRestoration.swift:879 (a suspended fork that moves on disk keeps a live session that writes its old record back to index.md), SessionRestoration.swift:233 (the switchingModel doc about suspended forks), ModelSwitchRestoreTests.swift:388 (no test of the modelChanged event, slot or context of a moved fork), SessionRestoration.swift:272 (withForks: true is reached only from tests). No caller in Sources or in FoundationModelsACPAgent/Sources claims a fork run or uses restored forks through a root restore: ACPAgent claims come from the agent runner of the root only.
    - next: /implement the open items of the Review Findings (2026-11-18 20:34) section.
  timestamp: 2026-11-19T02:38:43.050162+00:00
- actor: claude-code
  id: 01m7rtr3yn3y8nx00fjpweafdx
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionRestoration.swift, SessionTreeRestoration.swift, HookLineageTests.swift, ModelSwitchRestoreTests.swift
    - test: green — one full swift test run, 3056 tests in 349 suites (+49, +19), 0 failures
    - commit: a069e55e
    - review: findings — SessionTreeRestoration.swift:862, :866 (duplication), :879 (a suspended fork that moves gets its old record written back), SessionRestoration.swift:233 (doc), :272 (the withForks: true path is reached only by tests), ModelSwitchRestoreTests.swift:388 (event, slot and context of a moved fork not tested)

    Orchestrator decision for :879 and :233: a fork that has a session in the session directory, suspended or not, is live for this rule and does NOT move with the root. Only a recorded fork with no session moves on disk. The test aSuspendedForkMovesWithTheRoot changes to expect no move.
  timestamp: 2026-11-19T02:39:07.733909+00:00
- actor: claude-code
  id: 01m7rvp06qt4psq8ry11ttapn6
  text: |-
    Pass 2 (review findings 2026-11-18 20:34). Work done:
    - Rule changed per orchestrator decision: moveRecordedForks skips each fork that the session directory holds, live or suspended (isLive replaced by hasSession: `sessionDirectory?.session(id:) != nil`). Only a recorded fork with no session moves on disk.
    - Duplication: new SessionRecord.movesModel(to:) (slot or model differs from the handle) and SessionRecord.moveModel(to:) (sets slot, model, context of the handle). rebuild and moveRecordedForks both use them.
    - withForks removed from restoreSessionTree: no parameter, no parent guard, no child walk, one-node requireClaimable, no hooksById, no per-root instructions/hook-key test. SessionTreeRestorationError.notARootSession removed (nothing threw it any more; no user in sibling repos). RestoredSessionTree lost sessionsById, tree, session(_:), children(of:).
    - Tests that read forks from a root restore now restore each fork by its own id (RecordedForkTreeRestoreTests, HookLineageTests, SessionTreeRestorationToolWiringTests, SessionTreeRestorationLostRunTests, RestoreFidelityTests, RepetitionStopRestoreTests, RelayedQuestionContextTests, RouterSessionDirectoryForkTests, one integration assertion of children removed). The notARootSession test became "restoring by the id of a recorded fork restores no fork under it".
    - Discovery: Workspace.modelChangedEvents(of:) read the effective events of a fork, which include the modelChanged event of its moved source after the cut. The helper now filters by sessionId, else a live fork seems to get one event.
    - Mistake to avoid: a python edit of SessionFixtureLifecycle.swift that cut to the last `}` of the file deleted the SessionDirectoryFixture protocol below the enum; restored from git and redone.
    RED: ModelSwitchRestoreTests, 24 tests: the 3 suspendsFork=true cases failed (model, slot/context, event) as expected.
  timestamp: 2026-11-19T02:55:26.935539+00:00
- actor: claude-code
  id: 01m7rw4c79fp9n7rgkde79kvp3
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, SessionRestoration.swift, Tracing/RouterTelemetry.swift and Session/RoutedSessionActorWorkEvents.swift (doc links only); tests: ModelSwitchRestoreTests, RecordedForkTreeRestoreTests, HookLineageTests, SessionTreeRestorationToolWiringTests, SessionTreeRestorationLostRunTests, RestoreFidelityTests, RepetitionStopRestoreTests, RelayedQuestionContextTests, RouterSessionDirectoryForkTests, Helpers/SessionFixtureLifecycle.swift, IntegrationTests SessionTreeRestorationIntegrationTests (one children assertion removed). RED: ModelSwitchRestoreTests 24 tests, 3 suspended-fork cases failed. GREEN: 37 restore suites (421 tests) passed after the HookLineage migration (HookLineageTests 32 passed). Full swift test once: 3061 tests in 349 suites, plus 49 and 19, exit 0, no compiler warnings. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full2.txt
    - not verified: `swift build --package-path IntegrationTests --build-tests` fails in the unchanged file Sources/FoundationModelsRouter/Directory/UserMessageHeader.swift (`SessionSummary` has no member `shortID`). IntegrationTests/.build holds an older FoundationModelsExtras checkout. This is not caused by this change. A `swift package update` there (see the sourcekit-lsp memory) is necessary before the integration package compiles.
    - public API change: SessionTreeRestorationError.notARootSession removed (nothing throws it).
    - next: /review
  timestamp: 2026-11-19T03:03:17.993142+00:00
- actor: claude-code
  id: 01m7rwnx2ba1p5z19ccb8kf5jy
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 10 engine findings (10 confirmed, 8 refuted). 3 are recorded: Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift:366, :425, :501 (the new moved-fork and fork-with-a-session tests repeat the fork, switch and close setup). 7 are dropped by the review skill rule for tests that existed before: HookLineageTests.swift:517, :560, :599; RecordedForkTreeRestoreTests.swift:484, :657, :681, :730.
    - prior items: the 6 items of Review Findings (2026-11-18 20:34) are fixed. SessionRecord.movesModel(to:) and moveModel(to:) are used by rebuild and moveRecordedForks. hasSession(_:) skips each fork that the session directory holds, live or suspended. The switchingModel doc agrees with that rule. ModelSwitchRestoreTests has tests for the event, the slot and the context of a moved fork, and for no move of a fork with a session (both cases). restoreSessionTree has no withForks path.
    - API removal: no file in /Users/wballard/github/swissarmyhammer/*/Sources other than this package uses restoreSessionTree, RestoredSessionTree, session(_:), children(of:) of the tree or notARootSession. Production reached the removed path only from tests.
    - test helper: modelChangedEvents(of:) keeps only events with the sessionId of the session. The move writes its event with the id of the fork (appendRestoreEvent uses node.id). The dropped events are events of the source that forkPrefix keeps after the last entry of the cut. No production code reads modelChanged from effective events. Thus the filter hides no event that the change writes.
    - next: /implement the 3 open items of Review Findings (2026-11-18 21:06).
  timestamp: 2026-11-19T03:12:52.299885+00:00
- actor: claude-code
  id: 01m7rwpr41g65032s9r6mdz1vx
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — SessionTreeRestoration.swift, SessionRestoration.swift, 10 unit test files, 1 integration test file (the integration package compiles with `swift build --build-tests` after a dependency update)
    - test: green — one full swift test run, 3061 tests in 349 suites (+49, +19), 0 failures
    - commit: 1f865ac7
    - review: findings — ModelSwitchRestoreTests.swift:366, :425, :501 (the new fork tests repeat one setup). The reviewer dropped 7 findings on tests that were there before, by the written rule of the review skill; the orchestrator accepts that.
  timestamp: 2026-11-19T03:13:20.001174+00:00
- actor: claude-code
  id: 01m7rwxtj8sy9gv9n11q95t2bx
  text: |-
    Implementation of the 3 open findings of 2026-11-18 21:06 (test file only, no behavior change):
    - `recordedForkAfterRootMove(in:)` replaces `suspendedSourceWithARecordedFork(in:)`. It writes the recorded fork, switches the root to flash, closes the restored session, and returns the fork id and the `index.md` record after the switch. The 5 moved-fork tests call it and keep only their assertion.
    - `forkSessionAfterRootMove(in:suspendsFork:)` is new. It makes the fork session, reads the `index.md` of the fork, switches the root, closes the restored session and the fork, reads the `index.md` again, and returns the fork and the two records. The 3 fork-with-a-session tests call it.
    - The index read after the switch was also repeated in each test. The helpers now return the record, so that read is in one place.
    - `aSuspendedForkKeepsItsDirectoryEntry` still calls `suspendedSourceWithAForkSession` directly, because it examines the directory before the close. The default value `suspendsFork: Bool = false` of that helper had no caller after the change, so it is removed.
    - The full suite shows one build-system line, `warning: missing creator for mutated node` for the mlx-swift_Cmlx.bundle in .build. It is a SwiftPM message about a bundle of a dependency, not a compiler warning of the source.
  timestamp: 2026-11-19T03:17:11.880938+00:00
- actor: claude-code
  id: 01m7rwxxtjv2y973y9qxm48xdr
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift. `swift test --filter FoundationModelsRouterTests.ModelSwitchRestoreTests`: 24 tests, 0 failures. Full `swift test` once (exit 0): 3061 tests in 349 suites passed, plus 49 and 19; 0 failures; log at /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-swift-test.log. The 3 findings of 2026-11-18 21:06 are `- [x]`.
    - next: /review
  timestamp: 2026-11-19T03:17:15.218693+00:00
- actor: claude-code
  id: 01m7rx0wqdhqvp46gdf0mezhm9
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (206ca77b): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 1 file reviewed (ModelSwitchRestoreTests.swift). All items of the two prior Review Findings sections are checked. The 3 items of the 2026-11-18 21:06 section are fixed.
    - next: none. The task is in done.
  timestamp: 2026-11-19T03:18:52.397908+00:00
- actor: claude-code
  id: 01m7rx1k5sq7m5ej20bbgs6xn3
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — ModelSwitchRestoreTests.swift (two setup helpers)
    - test: green — one full swift test run, 3061 tests in 349 suites (+49, +19), 0 failures
    - commit: 206ca77b
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-19T03:19:15.385622+00:00
position_column: done
position_ordinal: ffffffffffb680
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

## Review Findings (2026-11-18 20:34)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:862` `duplication/duplication` — The condition that decides whether a recorded fork moves repeats the test that decides whether the root moves. Both compare the recorded slot and model with the handle. The two checks can drift if one is changed and the other is not. Add one helper on SessionRecord, for example `func differs(slot: ModelSlot, model: ModelRef) -> Bool`, and use it in both places.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:866` `duplication/duplication` — The new moveRecordedForks writes the same three index fields that the root restore path already writes: slot, model and context. The two copies can drift apart. A later change to the index fields, such as a new field or a new rule for the context, must then be made in two places. Move the three assignments into one helper that takes a SessionRecord and returns it with the slot, model and context of a RoutedLLM set. Call it from both the root restore path and moveRecordedForks. The two writers may stay separate, because the live session uses updateRecord and the moved fork uses saveLoggingFailure. Only the field assignments need to be shared.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:879` `review/orchestrator-check` — `isLive(_:)` makes a suspended fork "not live", so `moveRecordedForks(_:)` writes its `index.md` and its `modelChanged` event. But a suspended session stays in the session directory and keeps its work until `close()` (`RoutedSession.suspend()`). It also keeps its own record in memory, and `updateRecord` saves that record to `index.md` (`recordSubmissionStart`, `recordCompactionCheckpoint`, the archive and unarchive of `RouterSessionDirectory`). The next such write puts the old slot, model and context back in the `index.md` of the moved fork. The events that the suspended session writes after the move also have the old model, after a `modelChanged` event that names the new model. Thus the move of a suspended fork is not durable, and the rule "its session owns its `index.md`" applies to a suspended fork too. Make one rule for each fork that the session directory holds: do not move it on disk, or move it through its live session (its `updateRecord`) so that the record in memory and the `index.md` agree.
- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:233` `review/orchestrator-check` — The doc of `switchingModel` says that a live fork "does not move, because its session owns its `index.md`" and that "a fork that the host suspended moves". A suspended fork also has a session that owns its `index.md` (see the finding on `isLive(_:)`). Make the doc agree with the rule that the fix of that finding sets.
- [x] `Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift:388` `review/orchestrator-check` — `moveRecordedForks(_:)` is a new write path, but the new tests examine only `record.model` of the fork. No test examines that a moved fork gets exactly one `modelChanged` event with the new slot and model, that its `index.md` gets the new slot and context, or that a live fork gets no `modelChanged` event. Add tests for these writes (`modelChangedEvents(of:)` of the `Workspace` helper reads the events).
- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:272` `review/orchestrator-check` — This call is the only production call of `restoreSessionTree`, and it now always gives `withForks: false`. The `withForks: true` path of `restoreSessionTree` (the default value `true` of the parameter, the guard on `rootNode.parentId`, the walk into `node.children`, and the walk in `requireClaimable`) is now reached only from tests. Production code that only tests reach is dead code. Remove the `withForks: true` path and move the tests that use it to `restoreSession(id:)`, or give the path a production caller.

## Review Findings (2026-11-18 21:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 7 engine findings are not on this list. Each asks for a refactor of a test that existed before this change, and the review skill drops such findings: `HookLineageTests.swift:517`, `:560`, `:599`; `RecordedForkTreeRestoreTests.swift:484`, `:657`, `:681`, `:730`. The commit changed one restore line and one close line in each of these tests.

- [x] `Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift:366` `duplication/duplication` — The sequence of building the recorded fork, switching the root to flash, and closing the restored session is copied in five tests. Each copy must be kept in step with the others. Add a helper that builds the recorded fork, switches the root, closes the restored session and returns the fork id and folder. Each test then keeps only its own assertion.
- [x] `Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift:425` `duplication/duplication` — The setup, switch and close block is repeated in this test, which differs from the others only in its final assertion. Use the shared switch helper proposed for line 366.
- [x] `Tests/FoundationModelsRouterTests/ModelSwitchRestoreTests.swift:501` `duplication/duplication` — The fork-with-a-session tests repeat the same setup, switch and close, and differ only in the final check. Three tests build the same fork and switch the same root. Add one helper that does the fork, the switch and the close, and returns the fork and the recorded index. Keep each test's assertion in its own body.
