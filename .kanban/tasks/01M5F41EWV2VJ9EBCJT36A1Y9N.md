---
assignees:
- claude-code
depends_on:
- 01M5F3DZXJ25NHD9NPCVCRNMCM
position_column: todo
position_ordinal: '9180'
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