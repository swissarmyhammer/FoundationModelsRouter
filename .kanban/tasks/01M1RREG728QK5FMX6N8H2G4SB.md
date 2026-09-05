---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rtqwbxq9eqepwbrvgxyav9
  text: |-
    Research and first implementation pass.

    Discoveries:
    - Swift 6 language mode (tools 6.1, no override). Region isolation rejects a non-Sendable closure that an actor hands to a `nonisolated` method on another actor. `withResolveLock` therefore takes `isolation: isolated (any Actor)? = #isolation` and forwards it to `AsyncSemaphore.withPermit`, which gains the same parameter (it had no callers). The body then runs on the caller's actor and never leaves its region. A method with an `isolated` parameter cannot also be `nonisolated`; the lock itself stays a `nonisolated let`.
    - The `load` closure the router hands to `ModelPool.acquire` must be `@Sendable`, because the pool actor runs it. `Router.acquireModel` marks its `load` and `wrap` closures `@Sendable` and constrains `Loaded: Sendable`.
    - `acquire` returns the `PoolEntry`. The router reads `entry.isFirstHold` (refcount == 1 under the resolve lock) to know that this call loaded the key, which is what `newKeys` tracked before.
    - The default-pool identity test must build one `Router` with no `pool:` argument. That is the one site in the unit target without a pool. It never resolves, so it puts nothing in the shared pool.

    Done so far: `ModelPool.swift` written, `Router.swift` rewired, two new tests in `PooledResidencyTests.swift`. `swift build --build-tests` is green. `swift test --filter PooledResidencyTests`: 15 tests in 1 suite passed. The sweep of the other 40 test files is in progress.
  timestamp: 2026-09-05T13:04:49.021808+00:00
- actor: claude-code
  id: 01m1rv3gd2xqx7nr63bg3x0tt8
  text: |-
    ### implement — changed
    - evidence: 44 files — Sources/FoundationModelsRouter/Resolution/ModelPool.swift (new), Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift, and 40 other test files that now name a pool
    - next: test

    ### test — green
    - evidence: `swift test` — 1221 tests in 132 suites passed (Swift Testing, 2 known issues from the pre-existing `withKnownIssue` sites in RealModelHarnessTests and BoundedWaitTests) and 83 tests in 10 suites passed (XCTest); 0 failed, 0 skipped, 0 `warning:` lines, 0 `error:` lines
    - next: commit

    ### commit — changed
    - evidence: edb1506 feat(router): move the residency pool into a process-wide ModelPool actor
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-05T13:11:09.986493+00:00
- actor: claude-code
  id: 01m1rwbfdr073243vyhfhv46z9
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 1 finding, 1 confirmed, 0 refuted — Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:167
    - next: implement — restructure the `makeRouter` doc comment at lines 164-167 into one `- Parameters:` list with `id` and `pool` as bulleted items, the style `SessionTreeRestorationTests.swift` uses

    ### finish iteration 1 — review found 1 finding
    - implement: changed — Sources/FoundationModelsRouter/Resolution/ModelPool.swift (new), Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift, 40 other unit-test files
    - test: green — `swift test`: 1221 tests in 132 suites passed (2 pre-existing known issues) and 83 tests in 10 suites passed; 0 failed, 0 skipped, 0 warnings
    - commit: edb1506
    - review: findings — Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:167 `completeness/invariant-propagation` doc-comment style mix (`- Parameter id:` beside a bulleted `- pool:`)
  timestamp: 2026-09-05T13:32:59.704344+00:00
- actor: claude-code
  id: 01m1rwcv84dw8z3c7n0x2tgejj
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift (the `makeRouter` doc comment now documents `id` and `pool` under one `- Parameters:` list)
    - next: test

    ### test — green
    - evidence: `swift test` — 1221 tests in 132 suites passed (2 pre-existing known issues) and 83 tests in 10 suites passed; 0 failed, 0 skipped, 0 `warning:` lines, 0 `error:` lines
    - next: commit
  timestamp: 2026-09-05T13:33:44.580601+00:00
- actor: claude-code
  id: 01m1rwczstjk1gs7ykpdg6n8gv
  text: |-
    ### commit — changed
    - evidence: 542c760 docs(tests): document makeRouter's id and pool in one parameter list
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-05T13:33:49.242330+00:00
- actor: claude-code
  id: 01m1rwf3smyb09gk53hspkybnp
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted; the one prior finding (SessionTreeRestorationToolWiringTests.swift:167) is checked
    - next: done

    ### finish iteration 2 — review clean, card moved to done
    - implement: changed — Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift
    - test: green — `swift test`: 1221 tests in 132 suites passed (2 pre-existing known issues) and 83 tests in 10 suites passed; 0 failed, 0 skipped, 0 warnings
    - commit: 542c760
    - review: clean — no open findings
  timestamp: 2026-09-05T13:34:58.868165+00:00
position_column: done
position_ordinal: ffffc580
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
- [x] `Router(pool:)` compiles with the default `.shared`; every existing call site outside the unit target compiles unchanged.
- [x] `Router.swift` holds no `pool`, `poolLock`, or `residentProfiles` storage, and no `preconditionFailure` for a missing pool key.
- [x] A `package` accessor `Router.pool` exists so a test can assert the default is `ModelPool.shared`.
- [x] `rg -n 'Router\(' Tests/FoundationModelsRouterTests` finds no construction without a `pool:` argument, either direct or through a `makeRouter` whose default is a fresh `ModelPool()`. The one exception is the identity test for the default pool, which never resolves.
- [x] Every test in `PooledResidencyTests` passes unchanged in intent with a fresh pool per router.
- [x] `swift test` is green with no new warnings.

## Tests
- [x] New test in `PooledResidencyTests.swift`: a `Router` built with no `pool` argument reports `router.pool === ModelPool.shared`.
- [x] New test in `PooledResidencyTests.swift`: a `Router` built with an explicit `ModelPool()` reports that pool, not `.shared`, and `residentModelCount` goes 0 → 3 → 0 across one resolve and one release.
- [x] Run `swift test --filter PooledResidencyTests` → all pass.
- [x] Run `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router

## Review Findings (2026-09-05 08:11)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 43 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:167` `completeness/invariant-propagation` — Pool parameter documentation uses `///   - pool:` format (multi-parameter style), but existing id parameter documentation at line 164 uses `/// - Parameter id:` format (single-parameter style). This creates documentation format inconsistency within the function. The same pool parameter is documented consistently in SessionTreeRestorationTests.swift using multi-parameter format under a `/// - Parameters:` header, establishing the expected invariant. Standardize documentation format. Either convert line 167 to `/// - Parameter pool:` to match id's single-parameter style, or restructure lines 164-167 to use multi-parameter format: replace with `/// - Parameters:` header and convert both id and pool to bulleted items (`///   - id:`, `///   - pool:`) matching SessionTreeRestorationTests.swift style.