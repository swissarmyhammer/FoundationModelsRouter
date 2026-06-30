---
depends_on:
- 01KWC5FTDFTSW3BA82MXE6CGP0
- 01KWC5ECCZYEAH49J635KC9QH5
position_column: todo
position_ordinal: '9180'
title: RoutedSession actor + recording chokepoint + makeSession (milestone 5b)
---
## What
The generation session surface, born holding a recorder. Plan "Access API", "Sessions & KV cache" (basic), "Sessions: working directory & isolation", "Transcripts & recording" (chokepoint). Forking + concurrency gates are milestone 9; full nesting/manifest is milestone 10.

- `Sources/FoundationModelsRouter/RoutedLLM.swift`:
  - `func makeSession(instructions: String? = nil, workingDirectory: URL? = nil) -> RoutedSession`, vending a session that inherits the `RoutedLLM`'s `routerID` + non-optional `TranscriptRecorder` (from milestone 4b).
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:
  - `protocol RoutedSession: Actor` with `profile` (retained), `routerID: ULID`, `id: ULID`, `parentID: ULID?`, `recordingDirectory: URL`, `workingDirectory: URL` (defaults to recordingDirectory), `respond(to:)`, `streamResponse(to:)` (unconstrained text only). `fork(workingDirectory:)` declared but its real KV-copy behavior is milestone 9.
  - Concrete actor backed by `MLXLMCommon` `ChatSession` / `ModelContainer`. **No public initializer** — only vended by `RoutedLLM.makeSession`; recorder + `routerID` flow down from the Router.
  - **Single bracketed `generate` chokepoint:** every public method (`respond`, `streamResponse`) funnels through one private `generate` that runs the model inside a recorder bracket (open event → body → close/error in `defer`). Recorder is a non-optional `let`; milestone 10 enriches the events + nesting.
  - The raw `ChatSession` is never vended.

## Acceptance Criteria
- [ ] `makeSession().respond(to:)` returns text (covered for real in the gated integration suite); with a stub model the chokepoint emits exactly one open + one close event to an `InMemoryRecorder`, and a close event even when the body throws.
- [ ] A session retains its profile: dropping the profile handle while a session is alive does NOT evict; eviction happens after the last session is released (assert via the eviction spy from milestone 5a).
- [ ] `workingDirectory` defaults to `recordingDirectory` and is overridable via `makeSession(workingDirectory:)` without moving the recording directory.
- [ ] There is no public `RoutedSession` initializer (compile-time: construction only via `makeSession`).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SessionChokepointTests.swift` (Swift Testing) with a stub `ModelContainer`/loader + `InMemoryRecorder`: chokepoint emits open/close (incl. on throw); profile-retention via eviction spy; workingDirectory default + override.
- [ ] Run `swift test --filter SessionChokepointTests` — all pass.

## Workflow
- Use `/tdd` — write failing chokepoint + retention + workingDirectory tests with stubs first.