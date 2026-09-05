---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Extract the residency pool from Router into a process-wide ModelPool actor
---
Plan: `model-pool.md` §2.1, §2.4, §2.7.

## What
Move the resident-model pool out of `Sources/FoundationModelsRouter/Router.swift` into a new actor `Sources/FoundationModelsRouter/Resolution/ModelPool.swift`, so one pool serves every `Router` in a process.

- Move `ResidencyKey`, `PoolEntry`, `PooledContainer`, and `ResidencyHold` into `ModelPool.swift` and make them `package`.
- `public actor ModelPool` with `public static let shared = ModelPool()`, `public init()`, and `public var residentModelCount: Int` (the number of entries in the pool, for a host that wants to see what a process holds).
- The resolve-wide lock is a `nonisolated let` `AsyncSemaphore` exposed through one closure-taking method, `withResolveLock(_ body:)`. Not `lock()`/`unlock()`: an isolated `unlock()` cannot run inside `defer`, and an actor does not make check-then-insert atomic across an `await`. The lock is what stops two routers from loading one key two times.
- `acquire(...)` returns the `PoolEntry`, not the key. `runResolve` keeps the entry beside each slot's hold and passes it into `buildProfile`, `makeRoutedModel`, `makeRoutedLLM`, and `makeRoutedEmbedder`, which stay synchronous and no longer read `pool[key]` or trap on a missing key.
- `PoolEntry` gains an `evict: @Sendable (any LoadedModelContainer) async -> Void` closure captured from the loader of the router that loaded the key. An eviction at zero references runs through that closure, whichever router releases last.
- `Router.init` gains `pool: ModelPool = .shared`. `Router.residentProfiles` moves into the pool, keyed by residency token. `LanguageModelProfile.release()` keeps calling `router.release(token:)`, which forwards to the pool.
- Every router-building site in `Tests/FoundationModelsRouterTests` names a pool. There are 64 `Router(` constructions in 41 files, most inside a private `makeRouter` per suite. Each private `makeRouter` gains `pool: ModelPool = ModelPool()`; each direct `Router(...)` call passes `pool: ModelPool()`. This keeps parallel suites isolated: stub refs such as `org/std-shared` repeat across suites, and the budget arithmetic in `PooledResidencyTests` and `ResolveTests` must not depend on scheduling.

Keep the accounting rules unchanged: `baseFootprintBytes`, `acquiredChargeBytes`, `footprintBytes`, refcount, and the catch-path give-back in `runResolve`.

## Acceptance Criteria
- [ ] `Router(pool:)` compiles with the default `.shared`; every existing call site outside the unit target compiles unchanged.
- [ ] `Router.swift` holds no `pool`, `poolLock`, or `residentProfiles` storage, and no `preconditionFailure` for a missing pool key.
- [ ] A `package` accessor `Router.pool` exists so a test can assert the default is `ModelPool.shared`.
- [ ] `rg -n 'Router\(' Tests/FoundationModelsRouterTests` finds no construction without a `pool:` argument, either direct or through a `makeRouter` whose default is a fresh `ModelPool()`.
- [ ] Every test in `PooledResidencyTests` passes unchanged in intent with a fresh pool per router.
- [ ] `swift test` is green with no new warnings.

## Tests
- [ ] New test in `PooledResidencyTests.swift`: a `Router` built with no `pool` argument reports `router.pool === ModelPool.shared`.
- [ ] New test in `PooledResidencyTests.swift`: a `Router` built with an explicit `ModelPool()` reports that pool, not `.shared`, and `residentModelCount` goes 0 → 3 → 0 across one resolve and one release.
- [ ] Run `swift test --filter PooledResidencyTests` → all pass.
- [ ] Run `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router