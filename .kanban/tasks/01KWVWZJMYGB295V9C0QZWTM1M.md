---
assignees:
- claude-code
depends_on:
- 01KWVWYKPP6RAJTCX9MRQGZWA4
position_column: todo
position_ordinal: '8380'
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