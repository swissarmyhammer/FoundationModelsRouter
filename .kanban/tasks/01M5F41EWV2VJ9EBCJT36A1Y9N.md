---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f88y0bn1f3e95eebx7n4a4
  text: |-
    Notes:
    - Restore: `restoreSessionTree`'s per-node rebuild passes `facts: try SessionFacts.restored(from: node.directory)` to `makeRoutedSessionActor`. `SessionFacts.restored(from:)` (internal, SessionFacts.swift) returns the file's facts, or empty facts plus one `.warning` on the `Recording` logger ("the restored session has no facts.json; it restores with empty facts", file path in metadata) and writes nothing. A facts.json that is present but damaged, or stamped newer, still throws from `read(from:)` and fails the restore, the same as a damaged sidecar; the card covers only the missing-file case.
    - Fork: `performFork` passes `facts: facts.forFork`; `SessionFacts.forFork` keeps agentID, agentName, tags, sets origin `.fork`, and has no title, no startedBy, no archivedAt. The child writes it through the existing `.new` origin path beside its sidecar. This closes the interim caveat on ^vcrnmcm (empty fork facts, empty restored facts).
    - Test note: `restoreSession(id:)` refuses a fork id (`notARootSession`), so the restored-fork test restores the source's tree with `restoreSessionTree(root:)` and reads the fork node from it.
    - The warning test reads `context.logRecords` from `TelemetryCapture.run` directly (filtering on `.warning` and the message), since it counts records; `expectLogged` only checks presence.
  timestamp: 2026-10-21T12:51:42.219363+00:00
- actor: claude-code
  id: 01m5f890p5vkfvqk99ck90rm1x
  text: |-
    ### implement — changed
    - evidence: Sources: Recording/SessionFacts.swift (forFork, restored(from:)), Recording/SessionTreeRestoration.swift, Session/RoutedSessionActorForking.swift. Tests: SessionFactsRestoreTests.swift (4 tests). RED: 4 failing (restore gave empty facts, no warning, fork facts empty; restoreSession(id:) of a fork threw notARootSession -> test moved to restoreSessionTree). GREEN: `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" note); full `swift test`: 1959 tests / 245 suites passed with 9 known issues; 28 / 16; 19 / 3. SessionRestorationTests, SessionTreeRestorationTests and the fork tests pass unchanged.
    - next: review
  timestamp: 2026-10-21T12:51:44.965824+00:00
depends_on:
- 01M5F3DZXJ25NHD9NPCVCRNMCM
position_column: review
position_ordinal: '8280'
title: 'ROUTER-1: A restore reads facts.json back and a fork writes its own facts'
---
## Goal
Facts survive a restore, a session recorded before this change restores with empty facts, and a fork gets its own `facts.json`.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-1-session-facts
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.1 (tests: "A restore reads the facts back. A session with no `facts.json` restores with empty facts.")

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` (`restoreSessionTree`): read `facts.json` (`SessionFacts.read(from:)`) of each restored node and give it to `makeRoutedSessionActor`. A node with no file (a session from before this change) gets empty facts and one log warning, not an error; the restore does not write a file for it.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift` (`fork(workingDirectory:)` and its child construction): the child copies the agent id, agent name and tags of its source, has no title and no `startedBy`, has origin `.fork`, and writes its own `facts.json` next to its sidecar.

## Subtasks
- [ ] Failing test first: vend with facts, close, `restoreSession(id:)`; the restored `session.facts` equal what was written, including a `folder:` agent id.
- [ ] Read the facts at each restored node of the tree.
- [ ] A recording with no `facts.json` restores with empty facts and one warning (log assertions helper `Tests/FoundationModelsRouterTests/Helpers/LogAssertions.swift`).
- [ ] A fork writes `facts.json` with origin `.fork` and the agent and tags of its source; a restored recorded fork reads it back.

## Acceptance Criteria
- [ ] `restoreSession(id:)` gives a session whose `facts` equal the written facts.
- [ ] A restore of a recording with no `facts.json` succeeds with empty facts and logs exactly one warning.
- [ ] A fork's `facts.json` has origin `fork`, the source's agent id and tags, and no title.
- [ ] `SessionRestorationTests`, `SessionTreeRestorationTests` and the fork tests still pass.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionFactsRestoreTests.swift`
- [ ] `swift test --filter SessionFactsRestore` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording