---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwyqvwbgv0xtr6fz6g7q6mvm
  text: |-
    Implemented per spec:

    - Sources/FoundationModelsRouter/Session/RoutedSession.swift: replaced `private nonisolated let container: any LoadedLLMContainer` with `private nonisolated let backend: any LanguageModelSessionBackend`; removed `cache: any SessionKVCache` field and init param entirely. `respond(to:maxTokens:)` and `streamGenerating(...)` no longer manufacture a fresh backend per call (dropped the `let backend = container.makeSession(instructions: instructions)` lines) — they now call `backend.respond(...)` / `backend.streamResponse(...)` directly against the actor's own persistent backend. Guided path calls `backend.respond(to:following:maxTokens:)` the same way.
    - `fork(workingDirectory:)`: added `await serialGate.wait()` before `backend.makeFork()`, captured the forked backend into `forkedBackend`, then `serialGate.signal()` before constructing the child `RoutedSessionActor` — with a comment explaining the transcript data race this closes (a concurrent generation suspended inside `backend.respond()` could be mutating `LanguageModelSession.transcript` while `makeFork()` reads it). Child actor is now constructed with `backend: forkedBackend` instead of `container: container` + `cache: cache.copy()`.
    - `instructions: String?` stays on the actor (per the task's literal init-param scope, which only called out replacing `container`+`cache`) but is now unused for generation — only carried forward to the child on fork. Retained rather than removed since nothing in the task description asked for its removal and RoutedLLM.swift's builder still forwards it; updated its doc comment to reflect the new reality (baked into `backend` at construction).
    - Updated stale doc comments referencing `SessionKVCache`/prefix-reuse-primitive discussion on the `fork(workingDirectory:)` protocol requirement and the class-level `RoutedSessionActor` doc, since `cache` no longer exists — replaced with backend/transcript-seeded-fork wording.
    - Sources/FoundationModelsRouter/RoutedLLM.swift: `makeSession(grammar:instructions:workingDirectory:)` now calls `container.makeSession(instructions: instructions)` once to build `backend`, and passes `backend:` to `RoutedSessionActor.init`, dropping `cache: InertKVCache()`.
    - Did NOT touch Session/SessionKVCache.swift (InertKVCache/SessionKVCache protocol) — it's now unreferenced by production code but is in scope for a separate future task (070qw7z, KV cache proving), not this one.

    Verification: `swift build --target FoundationModelsRouter` — exit 0, "Build complete!". `swift build --build-tests` fails as expected/documented in the task's Tests section: Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift's `StubLLMContainer` doesn't conform to the (already-changed-by-a-prior-task) `LoadedLLMContainer.makeSession(instructions:)` shape — that's task qzwtm1m's job, not this one's. Did not touch test files.

    Ran adversarial double-check agent per really-done workflow before handoff; leaving task in `doing` for review per /implement policy.
  timestamp: 2026-07-07T16:51:31.824965+00:00
- actor: claude-code
  id: 01kwyqybc77j9ybgskcdfhhse9
  text: |-
    Adversarial double-check agent verdict: PASS, no findings. It independently re-ran `swift build --target FoundationModelsRouter` (exit 0, "Build complete!") and confirmed all 5 acceptance criteria against the actual diff (backend stored property with container/cache gone; fork() acquires serialGate before makeFork() with an explanatory race comment, releases before constructing the child; instructions no longer passed per generation call; RoutedLLM.swift builds the backend once and passes it in; library build green).

    Leaving task in `doing` for `/review` per /implement policy — really-done verification (library build green) plus adversarial sign-off both complete.
  timestamp: 2026-07-07T16:52:52.743927+00:00
depends_on:
- 01KWVWY278TRWBE16W000PE5CF
position_column: doing
position_ordinal: '80'
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