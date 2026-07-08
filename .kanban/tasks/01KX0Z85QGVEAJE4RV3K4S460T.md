---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Delete vestigial SessionKVCache.swift and its stale references
---
## What

`Sources/FoundationModelsRouter/Session/SessionKVCache.swift` (the `SessionKVCache` protocol and its sole conformer `InertKVCache`) is dead code. It predates the `LanguageModelSession`-as-factory pivot (tasks 00pe5cf/rqgzwa4/qzwtm1m, already landed): `RoutedSessionActor` no longer holds a `cache:` property at all (removed in task rqgzwa4), and `RoutedLLM.makeSession` no longer constructs an `InertKVCache` anywhere. Confirmed via grep across `Sources/`: the only occurrences of `SessionKVCache`/`InertKVCache` are inside `SessionKVCache.swift` itself — zero other production call sites.

The real fork/transcript-continuation mechanism today is `LanguageModelSessionBackend.makeFork()` (see `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift` and `MLXFoundationModelsSessionBackend.makeFork()` in `LiveModelLoader.swift`), which is unrelated to this file. `SessionKVCache`'s own doc comment already documents itself as a historical leftover ("Historical note — not currently backed by real MLX KV state... This protocol predates the `LanguageModelSession` pivot") and claims the fork/copy/free lifecycle "is still unit-tested" — that claim is now false too: the `SpyKVCache`/`CacheCensus` unit tests that exercised it in `ForkConcurrencyTests.swift` were already deleted in task qzwtm1m as part of the stub migration. There is no test coverage of this file left anywhere (confirmed via grep across `Tests/` — the only remaining hit is a stale comment, not a type reference).

## Changes

1. Delete `Sources/FoundationModelsRouter/Session/SessionKVCache.swift` entirely (both `SessionKVCache` and `InertKVCache`).
2. `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift` lines ~328-333 — a comment block references `SessionKVCache` ("Its `SessionKVCache` is still just the copy/free object contract (asserted with a spy in the unit suite)..."). That spy no longer exists (removed in qzwtm1m) and the type will no longer exist after this task — rewrite or remove this comment so it doesn't reference a deleted type or a deleted test.
3. `plan.md` line ~819 — "`SessionKVCache` stays an inert copy/free lifecycle contract for every current conformer, live included." Remove or rewrite this sentence in the "Sessions & KV cache" section now that the type is gone; the section should describe only the real mechanism (`LanguageModelSessionBackend.makeFork()` / transcript continuation) without mentioning a protocol that no longer exists.

## Acceptance Criteria
- [ ] `Sources/FoundationModelsRouter/Session/SessionKVCache.swift` no longer exists
- [ ] No remaining reference to `SessionKVCache` or `InertKVCache` anywhere in `Sources/`, `Tests/`, or `plan.md`
- [ ] `swift build --build-tests` succeeds
- [ ] `swift test` passes (full suite, same as current baseline — no regressions)

## Tests
- [ ] No new tests needed — this is a pure deletion of already-untested dead code; existing suite must stay green throughout.