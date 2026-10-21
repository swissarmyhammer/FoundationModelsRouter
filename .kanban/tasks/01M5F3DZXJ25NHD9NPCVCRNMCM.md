---
assignees:
- claude-code
depends_on:
- 01M5F3D4VMZDN4VPA8D2MY7ET8
position_column: todo
position_ordinal: '8280'
title: 'ROUTER-1: SessionConfiguration carries the facts, a vend writes facts.json, and the session holds its facts'
---
## Goal
The first `facts.json` of each new session comes from its `SessionConfiguration`, and the live session holds its facts where synchronous code can read them and the directory can rewrite them (tags, title, archive). The restore and fork side is the next ROUTER-1 card.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-1-session-facts
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.1
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 13.3

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/SessionConfiguration.swift`: add `agentID: String?`, `agentName: String?`, `tags: Set<String>`, `title: String?`, `startedBy: ULID?`, `origin: FoundationModelsExtras.SessionOrigin?` (qualified: `hookOrigin` already uses the Hooks `SessionOrigin`), each with a default in `init` so no caller changes. They are not in `persistable` (the sidecar stays as it is).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/RoutedLLM.swift` (`makeSession(configuration:)` and the internal `makeSession(grammar:...)`): build the initial `SessionFacts` and pass them to `makeRoutedSessionActor`.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift`: the actor keeps its facts in a `Mutex<SessionFacts>` so they are readable with no `await` (the directory's synchronous `register` builds the `started` summary from them). It writes the first `facts.json` where the `SessionSidecarOrigin.new` sidecar is written (`Recording/SessionSidecar.swift`). An internal `updateFacts(_ change: (inout SessionFacts) -> Void) throws -> SessionFacts` rewrites the file atomically and then swaps the value.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSession.swift`: `nonisolated var facts: SessionFacts { get }`.
- The kind (root, subagent, fork) is not stored: it comes from `agentSpawn` and the fork link.

## Subtasks
- [ ] Failing test first: a session vended with agent id, tags, title, `startedBy` and origin writes `facts.json` with those values, and its `session.json` has no new key.
- [ ] Add the configuration fields and thread them through the vend path to the actor's first write.
- [ ] Add `nonisolated var facts` (Mutex-backed) on `RoutedSession`, readable from a synchronous context.
- [ ] Add the internal `updateFacts`; a change rewrites `facts.json`, updates `facts`, and leaves `session.json` unchanged.

## Acceptance Criteria
- [ ] A new session's `facts.json` equals the facts of its configuration; `session.json` decodes to the same `SessionSidecar` as before this change.
- [ ] `session.facts` is readable with no `await` and equals the file.
- [ ] After `updateFacts`, `facts.json` and `session.facts` hold the new value and `session.json` is byte-for-byte unchanged.
- [ ] Existing `SessionSidecarTests` still pass.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionFactsRecordingTests.swift` with the scripted models of `Tests/FoundationModelsRouterTestSupport` and `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift`.
- [ ] `swift test --filter SessionFactsRecording` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording
