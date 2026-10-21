---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g9jns8m692pdm8rvnmbrmy
  text: 'Picked up; research done. RoutedModel (LanguageModelProfile.swift) gets `sessionDirectory: RouterSessionDirectory?` beside `hooks`; Router.makeRoutedModel passes `sessionDirectory` the way it passes `hooks`. RoutedLLM internal makeSession registers after makeRoutedSessionActor/bind (kind subagent when parentCall or agentSpawn, parent = parentCall?.sessionID ?? agentSpawn?.parentSessionId). RouterSessionDirectory.register is internal nonisolated sync, keyed by id, re-register replaces — so RouterSessionDirectoryQueryTests'' hand registration after vend still sets kind/parent (its doc comment saying vend sites register nothing goes stale and is updated). HandBuiltProfileFixtures passes no directory, so a hand-built profile''s sessions register nowhere. ToolContext for parentCall needs a RunPlane: cast the parent to RoutedSessionActor in the test.'
  timestamp: 2026-10-21T22:33:44.488456+00:00
- actor: claude-code
  id: 01m5g9vhmb0y3x9h0ehpz3wqdv
  text: |-
    Implementation landed (TDD). RED 1: new suite failed to compile (no RoutedModel.sessionDirectory). RED 2 after adding the link: 5 of 6 tests failed on missing registration (hand-built test passed, as expected for a guard). GREEN: RoutedLLM.makeSession computes `subagentParentID` once (shared with the hook lineage) and calls private `registerVendedSession` after `bind(delegationAdvisor:)`, before return. RouterSessionDirectoryQueryTests doc comment updated: its hand registration now re-registers (replaces) the makeSession registration. Full `swift test`: 2009 tests in 250 suites passed (9 known issues, pre-existing). The one build warning, `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, is SwiftPM build-system output that the baseline (changes stashed) also emits.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryRegistrationTests.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryQueryTests.swift; `swift test --filter RouterSessionDirectory` 21/21 pass; full `swift test` 2009 pass
    - next: /review
  timestamp: 2026-10-21T22:38:35.147017+00:00
depends_on:
- 01M5F3FCP6BTAZ5Q8FB6PEYQXN
position_column: doing
position_ordinal: '80'
title: 'ROUTER-3: A profile reaches its router''s directory, and each new root and subagent session registers'
---
## Goal
Answer Q37 (a profile cannot reach its `Router` today) by giving `RoutedModel` the directory of the router that resolved it, and register every session that `makeSession` vends (root and subagent) before it is returned. Fork, restore and close are the next card.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory ("Each session that the router vends ... registers itself"; D87 leaves the how to the implementation)
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md sections 2 (the vend points), 5.2 and 7 (Q37)

## What
- **Q37 answer:** `RoutedModel` (`/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/LanguageModelProfile.swift`) holds `routerId`, `recorder`, `hooks` and so on, but no router. Add `sessionDirectory: RouterSessionDirectory?` to its init, passed by `Router.resolve` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Router.swift` the same way it passes `hooks`. A hand-built profile with no router gives `nil`, and its sessions register nowhere.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/RoutedLLM.swift`, internal `makeSession(...)`: after `makeRoutedSessionActor` and before `return`, call the directory's `nonisolated` synchronous `register(session, kind:, parentID:)`: kind `subagent` when `parentCall` or `agentSpawn` is set (parent id = `parentCall?.sessionID ?? agentSpawn?.parentSessionId`), else `root`.

## Subtasks
- [x] Failing test first: a session from `router.resolve(...).standard.makeSession(configuration:)` is in `router.sessionDirectory.sessions(matching:)` with kind `root`.
- [x] Add the `RoutedModel` link and pass it from `Router.resolve`.
- [x] Register in `makeSession`; tests for a subagent by `parentCall` and by a recorded `agentSpawn`, each with its parent id.
- [x] Sessions of two routers in one process do not appear in each other's directory; a hand-built profile's session registers nowhere.

## Acceptance Criteria
- [x] A new root has `kind == .root` and no parent; a subagent has `kind == .subagent` and its parent id.
- [x] Registration happens before `makeSession` returns (the query right after the call finds it, with no wait).
- [x] Two routers keep separate directories.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryRegistrationTests.swift` (scripted models, no real model).
- [x] `swift test --filter RouterSessionDirectoryRegistration` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api
