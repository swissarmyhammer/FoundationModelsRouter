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
- actor: claude-code
  id: 01m5g88mpb76m86g04fwbndefm
  text: |-
    ### review — findings
    - evidence: review sha 251def1d~1..251def1d — 1 finding (1 confirmed, 0 refuted; 7 attempted, 0 failed) — Tests/FoundationModelsRouterTests/SessionFactsRestoreTests.swift:18 (reuse/reuse). The engine did not raise the best-effort facts.json/session.json write question tracked on ^vcrnmcm.
    - next: implementer resolves the unchecked item in "## Review Findings (2026-10-21 17:06)"; task stays in review; still blocked by ^vcrnmcm.
  timestamp: 2026-10-21T22:10:47.115829+00:00
- actor: claude-code
  id: 01m5g8eqstf33hqzgndj6ra46y
  text: |-
    Resolved reuse/reuse finding (SessionFactsRestoreTests.swift:18): added Tests/FoundationModelsRouterTests/Helpers/SessionFactsFixtures.swift with the shared fact constants (agentID, agentName, tags, title), `configuration(startedBy:)`, `expectedFacts(startedBy:)`, and `withRecordingProfile(prefix:_:)` (temp dir + durable-recording standard profile + cleanup). Removed `recordedFacts` from the restore suite; both suites now call the shared helpers. Same cause removed across both files: the duplicated temp-dir/profile setup (restore `withProfile`, recording `withVendedSession` and the inline setup in `aSessionWithNoFactFieldWritesEmptyFacts`) and the duplicated fact literals (fork expected facts, restored agentID check, updated tags). Note: the sah `edit file` `replace_all: true` replaced only the first match each time; I edited the remaining sites one by one.

    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTests/Helpers/SessionFactsFixtures.swift (new), Tests/FoundationModelsRouterTests/SessionFactsRestoreTests.swift, Tests/FoundationModelsRouterTests/SessionFactsRecordingTests.swift. `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" note); `swift test --skip-build --filter SessionFacts`: 19 tests / 3 suites passed, plus 1/1 public-surface.
    - next: review
  timestamp: 2026-10-21T22:14:06.906772+00:00
depends_on:
- 01M5F3DZXJ25NHD9NPCVCRNMCM
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-10-21 17:06)

> Scope: `review sha 251def1d~1..251def1d` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/SessionFactsRestoreTests.swift:18` `reuse/reuse` — Duplicates the identical `configuration(startedBy:)` function from SessionFactsRecordingTests without reusing it. Both create the same SessionConfiguration with identical parameters. This should call or extend the existing function rather than reimplementing it. Remove `recordedFacts` and instead call `SessionFactsRecordingTests.configuration(startedBy:)` in the test methods, or if that's not accessible, move the shared function to a common test helpers file and reuse from both test classes.
