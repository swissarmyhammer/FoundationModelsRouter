---
assignees:
- claude-code
depends_on:
- 01KWVWZJMYGB295V9C0QZWTM1M
- 01KWVYPJ0XX9K9NRVX8JKSPZ9Z
position_column: todo
position_ordinal: '8480'
title: Prove multi-turn conversation state and KV cache usage in router sessions
---
## What

Tests that prove both multi-turn correctness (session sees prior turns) AND that the KV cache is actually being reused across turns — not just that the transcript grows, but that previously processed tokens are not recomputed. This task is the hard proof that the router is usable at production speed.

**Unit tests** — new file `Tests/FoundationModelsRouterTests/MultiTurnSessionTests.swift`:
- Same `backend` instance is used for two `respond()` calls on one `RoutedSession`: assert `stubBackend.callCount == 2` after two calls
- `fork()` gives the child a backend whose `receivedPrompts` starts as a copy of the parent's call history
- `fork()` holds the `serialGate` during `makeFork()`: concurrent generation and fork don't race (verify via instrumented stub)

**Integration tests** — extend `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`:

**Test 1 — Transcript grows per turn:**
After 2 `respond` calls on one session, `(backend as! MLXFoundationModelsSessionBackend).session.transcript.entries.count == 4`. Access via `@testable import FoundationModelsRouter` and the `internal var session: LanguageModelSession` on `MLXFoundationModelsSessionBackend` (NOT on the protocol).

**Test 2 — Fork inherits transcript:**
Fork after 1 turn; the fork's `session.transcript.entries.count == 2` at creation.

**Test 3 — KV cache is reused (THE REQUIRED PROOF):**
Capture the `LanguageModelSession.usage` (or the executor's `.updateUsage` channel event) for turn 1 and turn 2 on the same session.
- Turn 1: `cachedTokenCount == 0` (nothing cached yet), `totalTokenCount == N`
- Turn 2: `cachedTokenCount > 0` — specifically, `cachedTokenCount` should equal approximately the turn-1 total token count (prompt + response), because those tokens were processed in turn 1 and are now cached
- `cachedTokenCount == 0` on turn 2 is a **hard test failure** — it means the fix in the fork task is not working and must be resolved before this task can pass

This test is the exit criterion for the whole caching effort. We are not done until this passes.

**Test 4 — Turn 2 is faster than turn 1 (optional, best-effort):**
Measure wall-clock time for turn 1 vs turn 2 on a session with a long system instruction. Turn 2 should be meaningfully faster because it only processes the new delta tokens. This is a heuristic/warning test (don't fail CI on timing), but log the ratio — a ratio near 1.0 is a signal the cache isn't working even if `cachedTokenCount` says otherwise.

## Acceptance Criteria
- [ ] Unit test: two `respond` calls on the same `RoutedSession` reach the same `StubSessionBackend` (callCount == 2)
- [ ] Unit test: fork's stub starts with parent's call history
- [ ] Integration test: `session.transcript.entries.count == 4` after 2 turns
- [ ] Integration test: fork's session starts with parent's transcript entries
- [ ] **Integration test: `cachedTokenCount > 0` on turn 2** — this is a hard requirement, not optional
- [ ] `swift test --filter MultiTurnSessionTests` passes
- [ ] Integration suite passes

## Tests
- [ ] `Tests/FoundationModelsRouterTests/MultiTurnSessionTests.swift` — new, 3+ unit test cases
- [ ] `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` — 4 new integration cases including the hard KV cache proof

## Workflow
- `/tdd` — write the `cachedTokenCount > 0` integration test first (it will fail until the fork task is complete), then the other tests. This task is blocked on both the stub-update task and the fork KV cache task.