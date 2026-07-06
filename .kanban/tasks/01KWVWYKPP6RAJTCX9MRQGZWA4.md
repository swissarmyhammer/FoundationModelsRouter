---
assignees:
- claude-code
depends_on:
- 01KWVWY278TRWBE16W000PE5CF
position_column: todo
position_ordinal: '8280'
title: Update RoutedSessionActor to own and drive a LanguageModelSessionBackend
---
## What

`RoutedSessionActor` must hold the `LanguageModelSessionBackend` as actor state for its lifetime. All generation and fork creation goes through the backend.

**Modify** `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:
- Replace `private nonisolated let container: any LoadedLLMContainer` with `private nonisolated let backend: any LanguageModelSessionBackend`
- Remove `private nonisolated let cache: any SessionKVCache`
- `respond(to:maxTokens:)` chokepoint: calls `backend.respond(to:maxTokens:)` — `instructions` no longer passed per call (baked into backend at construction)
- `streamGenerating(_:maxTokens:into:)`: calls `backend.streamResponse(to:maxTokens:)`
- Guided path: calls `backend.respond(to:following:maxTokens:)`
- `fork(workingDirectory:)`:
  - **Must acquire `serialGate` before calling `backend.makeFork()`** to prevent a transcript data race. A concurrent generation suspending inside `backend.respond()` (outside actor isolation) could be modifying the `LanguageModelSession.transcript` while `fork()` reads it. Acquire with `await serialGate.wait()`, capture the forked backend, then `serialGate.signal()` before constructing the child actor. Add a comment explaining the race.
  - Construct child `RoutedSessionActor` with the forked backend

**Modify** `Sources/FoundationModelsRouter/RoutedLLM.swift` — `makeSession(grammar:instructions:workingDirectory:)`:
- Call `container.makeSession(instructions: instructions)` to get the backend
- Pass `backend:` to `RoutedSessionActor` init, drop `cache:` param

**Update** `RoutedSessionActor.init(...)`:
- Accept `backend: any LanguageModelSessionBackend` in place of `container:` + `cache:`

## Acceptance Criteria
- [ ] `RoutedSessionActor` holds `backend: any LanguageModelSessionBackend`; `container` and `cache` are gone
- [ ] `fork()` acquires `serialGate` before calling `backend.makeFork()` with a comment explaining the transcript data race prevention
- [ ] `instructions` are no longer passed per generation call
- [ ] `swift build --target FoundationModelsRouter` succeeds

## Tests
- [ ] All existing chokepoint, fork, and transcript tests pass after stub updates in task 4
- [ ] `swift test` exits 0 (once task 4 stubs are done)

## Workflow
- `/tdd` — update the actor and builder, confirm production build passes, then task 4 fixes the test side.