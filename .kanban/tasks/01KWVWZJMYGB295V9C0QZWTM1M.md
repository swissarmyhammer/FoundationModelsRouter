---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwytz59syfg13hb38dfre8fx
  text: |-
    Implemented. Summary:

    - Added `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift` — shared `final class StubSessionBackend: LanguageModelSessionBackend, @unchecked Sendable` with `responseText`/`shouldThrow`, `callCount`/`receivedPrompts` tracking, and `makeFork()` seeding a child with a copy of `receivedPrompts`.
    - Simple stub replacement (all now `makeSession(instructions:) -> StubSessionBackend`): SessionChokepointTests, TranscriptNestingTests, ToolIntegrationTests, MergedAndRedactionTests, GuidedShapesTests, ResolveTests, ProfileLifecycleTests, ExamplesTests.
      - SessionChokepointTests and GuidedGenerationTests each needed to preserve their existing maxTokens-threading assertions (a `MaxTokensSpy` actor injected into the container); added a small local `MaxTokensRecordingBackend` wrapper in each file (composes a `StubSessionBackend`, since it's `final` and can't be subclassed) rather than baking maxTokens-observation into the shared helper.
    - GuidedGenerationTests.swift: `GuidedStubContainer` updated to the factory pattern; `DefaultGuidedContainer` (and its sole consumer `defaultContainerValidatesThenDefersLiveDecode`) deleted outright since it becomes dead code once the default `LoadedLLMContainer` guided extension no longer exists. Replaced with `validateForXGrammarAcceptsSupportedRejectsUnsupported`, a pure unit test asserting the same "supported schema passes / unsupported construct rejected" behavior directly against `Grammar.validateForXGrammar()`.
    - ForkConcurrencyTests.swift (biggest redesign): removed `SpyKVCache`/`CacheCensus`/`InstrumentedLLMContainer.makeCache()` entirely. Introduced a local `TrackingSessionBackend` (this file's flavor of a trackable backend — needs observer/release-gate parking + guided-grammar-probe recording that the shared `StubSessionBackend` intentionally doesn't carry) and made `InstrumentedLLMContainer` a simple `makeSession` factory that tracks the last-created backend. `StubModelLoader` now returns one fixed, test-supplied container instance (was constructing fresh ones per call) so tests can hold a live handle to inspect `callCount`/`receivedPrompts`/`lastFork`.
      - `forkCopiesCacheAndSetsParentId` → renamed `forkSeedsBackendFromParentAndSetsParentId`, asserts backend call/prompt-history inheritance at fork time instead of KV-cache copy count.
      - `releasingForkFreesItsCacheOnly` → renamed `forkedBackendDivergesIndependently`, asserts parent/child transcripts diverge independently post-fork instead of KV-cache free lifecycle (no cache abstraction to observe anymore).
      - `forkAdmissionBoundsConcurrentForks` → dropped the census-based liveForks/maxLiveForks/forkFrees assertions; kept the admission-gate-based assertions (availablePermits/waiterCount), which the pre-existing in-code comment already called "the robust bound evidence."
      - Removed now-unused `import Synchronization` (only used by the deleted `Mutex`-guarded `CacheCensus`).
    - `SessionKVCache`/`InertKVCache` (Sources) left untouched — unreferenced by production code, explicitly out of scope for this task per task 00pe5cf's comment (belongs to follow-up task 070qw7z).

    Verification: `swift build --build-tests` exit 0, `swift test` exit 0 — "Test run with 179 tests in 23 suites passed" (plus 3 gated/skipped integration tests). Filtered reruns of SessionChokepointTests, ForkConcurrencyTests, GuidedGenerationTests all green. Adversarial double-check agent returned PASS with no findings (verified protocol conformance, no dead code, no dropped coverage, no stale references to removed symbols).

    This is the task the whole stub-migration session was blocked on — `swift build --build-tests` and `swift test` are both fully green now, zero known blockers remaining. Leaving in `doing` for `/review`.
  timestamp: 2026-07-07T17:45:45.017100+00:00
depends_on:
- 01KWVWYKPP6RAJTCX9MRQGZWA4
position_column: doing
position_ordinal: '80'
title: Update all test stubs to implement the LanguageModelSessionBackend factory seam
---
## What

Ten test files have inline `LoadedLLMContainer` stubs with stateless `respond`/`streamResponse`/`makeCache` implementations — all broken after task 1. Two of those files require redesign, not just stub replacement.

**New shared test helper** — `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift`:
- `final class StubSessionBackend: LanguageModelSessionBackend`
- Configurable canned response text, optional throw
- `callCount: Int` and `receivedPrompts: [String]` for assertion
- `makeFork()` returns a new `StubSessionBackend` pre-seeded with a copy of the parent's `receivedPrompts` (simulates transcript inheritance without a real model)

**Files to update — simple stub replacement** (remove old stateless methods, add `makeSession(instructions:) -> StubSessionBackend`):
- `SessionChokepointTests.swift` — `CannedLLMContainer`
- `TranscriptNestingTests.swift` — `CannedLLMContainer`
- `ToolIntegrationTests.swift` — `CannedLLMContainer`
- `MergedAndRedactionTests.swift` — `CannedLLMContainer`
- `GuidedShapesTests.swift` — `GuidedStubContainer`
- `ResolveTests.swift` — `StubLLMContainer`
- `ProfileLifecycleTests.swift` — `StubLLMContainer`
- `ExamplesTests.swift` — `StubLLMContainer`

**Files requiring redesign:**

`GuidedGenerationTests.swift` — `GuidedStubContainer` (line 30), `DefaultGuidedContainer` (line 64):
- Update both stubs to `makeSession(instructions:) -> StubSessionBackend`
- **Delete** `defaultContainerValidatesThenDefersLiveDecode` (line 369) — this test exercises the `LoadedLLMContainer` default extension that task 1 removes; the behaviour it tested (grammar validation before `notWiredForLiveInference`) no longer has a hook. Replace its intent with a pure grammar-validation unit test that calls `grammar.validateForXGrammar()` directly.

`ForkConcurrencyTests.swift` — `InstrumentedLLMContainer`, `SpyKVCache`, `CacheCensus`:
- `SpyKVCache`, `CacheCensus`, and `InstrumentedLLMContainer.makeCache()` (line 144) are entirely removed — no `makeCache()` exists after task 1
- Replace all `census.copies`/`census.births`/`census.frees` assertions with assertions on `StubSessionBackend.callCount` and `receivedPrompts` to verify fork transcript inheritance
- `InstrumentedLLMContainer` becomes a simple `makeSession` factory returning a trackable `StubSessionBackend`

## Acceptance Criteria
- [ ] `StubSessionBackend` helper exists and is shared by all test files
- [ ] All 10 stubs implement `makeSession(instructions:)` returning `StubSessionBackend`
- [ ] `defaultContainerValidatesThenDefersLiveDecode` is deleted; a replacement grammar-validation test covers its intent
- [ ] `SpyKVCache`/`CacheCensus` are removed; `ForkConcurrencyTests` assertions use `StubSessionBackend` call history instead
- [ ] `swift test` exits 0

## Tests
- [ ] `swift test --filter SessionChokepointTests` passes
- [ ] `swift test --filter ForkConcurrencyTests` passes
- [ ] `swift test --filter GuidedGenerationTests` passes
- [ ] `swift test` (full suite) exits 0

## Workflow
- `/tdd` — run `swift test` first to see all failures, create `StubSessionBackend`, fix simple stubs, then tackle the two redesign files.