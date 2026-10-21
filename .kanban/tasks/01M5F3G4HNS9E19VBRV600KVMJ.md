---
assignees:
- claude-code
depends_on:
- 01M5F3FCP6BTAZ5Q8FB6PEYQXN
position_column: todo
position_ordinal: '8580'
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
- [ ] Failing test first: a session from `router.resolve(...).standard.makeSession(configuration:)` is in `router.sessionDirectory.sessions(matching:)` with kind `root`.
- [ ] Add the `RoutedModel` link and pass it from `Router.resolve`.
- [ ] Register in `makeSession`; tests for a subagent by `parentCall` and by a recorded `agentSpawn`, each with its parent id.
- [ ] Sessions of two routers in one process do not appear in each other's directory; a hand-built profile's session registers nowhere.

## Acceptance Criteria
- [ ] A new root has `kind == .root` and no parent; a subagent has `kind == .subagent` and its parent id.
- [ ] Registration happens before `makeSession` returns (the query right after the call finds it, with no wait).
- [ ] Two routers keep separate directories.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryRegistrationTests.swift` (scripted models, no real model).
- [ ] `swift test --filter RouterSessionDirectoryRegistration` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api
