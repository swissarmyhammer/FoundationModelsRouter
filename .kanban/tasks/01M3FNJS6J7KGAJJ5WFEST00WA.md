---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hws7rrp62t6k3cfv8xz9dj
  text: |-
    Research (Extras at f4bd503, `.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/ModelPool/`). Differences between the task text and the code (the code wins):
    - `ModelHold.deinit` removes the hold and its session bytes at once (under the pool lock). But the eviction job goes into the admission queue from a detached task. Thus an admission job that the router submits after the last release can run BEFORE that eviction job. Then the router sees the model as resident (its weights only), and a new hold of that key revives it. The task text says "the admission job sees every release that came before it". This is true for the hold count and the session bytes. It is not true for the eviction of the weights. Result: a resolve that starts at once after the drop of the last reference is not sure to see the freed weights. The old router pool gave this guarantee (`drainPendingReleases()` at the start of each resolve). Tests that must see an eviction now wait for it on a real signal: the `footprints` stream, then one empty admission job as a barrier. I add a follow-up task for the Extras repo.
    - `AsyncSemaphore` and `CancellableWait` stay. `LiveModelLoader` uses `CancellableWait` (lines 948 and 1015), and `CancellableWait` uses `AsyncSemaphore`. Test helpers and IntegrationTests also use the public `AsyncSemaphore`.
    - An admission job runs on a detached task (`GenerationQueue` job). Task locals do not go into the job. Thus the router gives the `ServiceContext` of the resolve span to the job, so that each load span stays a child of the resolve span (`ResolveTracingTests`).
    - `footprint`, `residentModelCount` and `isResident` are synchronous. Each `await pool.residentModelCount` in the tests must lose its `await` (else a warning).
    - There is no hold count in `ModelPoolFootprint`. The router finds a new key with `admission.footprint.resident[key] == nil` before the acquire (inside the job no other load or eviction can run).
    Prompt cache resize points:
    - This task keeps (inside the router admission job): before each acquire, a resize for the bytes that the acquire adds (a new key: its whole footprint, which is the old "before a load" point; a resident key: its session bytes, which is the old "a hold is added" point); after a failed acquire, a resize back to the resident footprint.
    - Task 01M3FNK00PYXP7E102NWNHMD56 (^wnhmd56) adds: a resize for a load by a caller that is not the router, and a resize after each release and eviction (the `footprints` stream). Between the two tasks, a release does not resize the prompt cache.
    Plan: `ModelPool` becomes a public typealias of the Extras class in `Resolution/PoolPrimitives.swift`; remove `Resolution/ModelPool.swift` and `ResidencyHold.swift`; `RoutedModel` keeps the three `ModelHold`s of its residency (so a handle alone keeps the whole trio resident, as before); `LanguageModelProfile.residencyToken` goes away (no token after this task); the embedding handle uses a new `PooledEmbeddingContainer` over `PooledEmbedder(hold:)`.
  timestamp: 2026-09-27T16:57:13.240038+00:00
- actor: claude-code
  id: 01m3hxz7gdc324yjeh3h7cf9wv
  text: |-
    ### implement — changed
    - evidence: Sources — Router.swift (resolve = sizing, then ONE `pool.admit` job: `runAdmission` measures `admission.footprint`, runs `JointFit`, and `acquireSlots` takes one `ModelHold` per slot through `SlotPoolLoader.acquireHold(of:in: ModelPoolAdmission, ...)`; prompt cache resize before each acquire and after a failed acquire; `ServiceContext` of the resolve span goes into the job), LanguageModelProfile.swift (`RoutedModel.residencyHolds: [ModelHold]`; `residencyToken` removed), Resolution/PoolPrimitives.swift (`public typealias ModelPool = FoundationModelsExtras.ModelPool`), Resolution/PooledEmbeddingContainer.swift (new), Resolution/SlotPoolLoader.swift, Sizing/PromptCacheBudget.swift (`PromptCacheSizing` removed, `resize(_:workingSetBytes:footprint:addedBytes:)` added), Concurrency/AsyncSemaphore.swift (dead `withPermitUnlessCancelled` removed; doc); removed Resolution/ModelPool.swift and ResidencyHold.swift. Tests — new ExtrasPoolResolveTests.swift (shared pool one load; router + direct acquire one load and residency until both release; direct acquire waits for the admission job of the router, signal = `pool.admissions.waitingCount`), new ModelPoolNameTests.swift (plain `import` of both modules, `ModelPool` compiles, one type); updated PooledResidencyTests, CrossRouterResidencyTests, ProfileLifecycleTests, PromptCacheBudgetTests, ResolveCancellationTests, ToolSharedProfileTests, SlotPoolLoaderTests, ReadmeSymbolsTests, OwningProfileTests, helpers; IntegrationTests PromptCacheBudgetIntegrationTests and CrossRouterPoolIntegrationTests. Docs — README.md, model-pool.md.
    - Decisions: `AsyncSemaphore.swift` and `CancellableWait.swift` stay (LiveModelLoader uses `CancellableWait`; tests use `AsyncSemaphore`). The name form: a public typealias; a file with plain `import FoundationModelsRouter` and `import FoundationModelsExtras` compiles `ModelPool` with no ambiguity, because the alias and the class are one declaration (ModelPoolNameTests). The stale-token test of ProfileLifecycleTests is removed: there is no token after this task. Tests that must see an eviction wait with `ModelPool.settle(until:)` (the `footprints` stream plus an empty admission job as a barrier). Follow-up task 01M3HXT453GXVBZPZFXXTZGP9Y records the eviction ordering of the Extras pool.
    - Verification: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1461 tests in 177 suites passed (2 known issues that two tests expect), plus 17 and 19; pool/residency/cross-router/prompt-cache/cancellation suites 10 times with `--parallel --num-workers 8` — 67 tests in 10 suites passed each time; `swift build --build-tests --package-path IntegrationTests` — no error, no warning.
    - next: /test
  timestamp: 2026-09-27T17:17:58.157610+00:00
- actor: claude-code
  id: 01m3hy0dtvhy40frhcv9tbwgry
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1461 tests in 177 suites passed (2 known issues that two tests expect on purpose), plus 17 tests in 8 suites and 19 tests in 3 suites; no skipped test; `swift build --build-tests --package-path IntegrationTests` — Build complete, no error, no warning; the pool, residency, cross-router, prompt-cache and cancellation suites 10 times with `--parallel --num-workers 8` — 67 tests in 10 suites passed each time.
    - next: /commit
  timestamp: 2026-09-27T17:18:37.403683+00:00
depends_on:
- 01M3FNBKR2347W659AXFJVZKGM
position_column: doing
position_ordinal: '80'
title: 'Router: swap Router.resolve to the Extras ModelPool and remove the router pool and ResidencyHold'
---
## What
Decision (user, 2026-09-26): the router uses the process-wide `ModelPool` in the core `FoundationModelsExtras` target (no new product or target). The router is the part that makes, manages, compacts and transcribes sessions. It is one user of the pool.

Blocked by Extras task 01M3FN95AM98RJSTCVQ8G1Z7KE (the pool actor, its hold type and its API names). Depends on router task 01M3FNBKR2347W659AXFJVZKGM (the loader conformance and the slot-to-role map).

- Remove `Sources/FoundationModelsRouter/Resolution/ModelPool.swift` and `Sources/FoundationModelsRouter/ResidencyHold.swift`.
- `Sources/FoundationModelsRouter/Router.swift`:
  - `init(... pool: ModelPool = .shared)` (line 103) takes the Extras `ModelPool`.
  - `resolve` (lines 212-366): replace the resolve lock with one Extras admission job: `pool.admit { admission in ... }`. Inside the job, read `admission.footprint`, run `JointFit`, resize the router's prompt cache for the loading bytes (see task 01M3FNK00PYXP7E102NWNHMD56), and call `admission.acquire(_:footprintBytes:sessionBytes:loader:)` for each slot. That acquire runs at once and does not queue again, so the job cannot wait for itself. The pool runs every load of a new key (also from the registry or the multitool) as a job in the same FIFO admission queue, so no other load can occur between the measurement and the acquire. Change `grant(token:charges:)` and `release(charges:)` to the Extras holds: each acquire returns its own `ModelHold`. A `ModelHold` releases synchronously in its deinit, and the admission queue runs the eviction as a job that checks the hold count again. Thus the router's `drainPendingReleases()` step at the start of resolve is removed; the admission job sees every release that came before it.
  - Remove the router's `Concurrency/AsyncSemaphore.swift` and `Concurrency/CancellableWait.swift` if no router code uses them after this change (`JointFit` and `Router.swift` used them for the resolve lock).
- `Sources/FoundationModelsRouter/LanguageModelProfile.swift:118`: `RoutedModel` keeps the Extras holds of its slots.
- The name `ModelPool`: router users write `ModelPool` today (for example `Router(pool: ModelPool())`). After this task there must be one `ModelPool` type. A file that imports both `FoundationModelsRouter` and `FoundationModelsExtras` must compile with no ambiguity.
- Update `README.md` and `model-pool.md` in the router repo: the pool and the hold now come from Extras, and the router is one user of the pool.

## Acceptance Criteria
- [ ] The router has no pool actor and no residency hold type of its own.
- [ ] Two routers on `ModelPool.shared` that resolve the same `ModelRef` cause one load.
- [ ] A model is evicted when the last router profile that holds it is released, as before.
- [ ] `README.md` and `model-pool.md` describe the Extras pool.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Update the router pool tests (the residency and eviction tests, the cross-router tests, and the `JointFit` tests with residents) to use the Extras pool.
- [ ] Add a test: a router and a direct Extras `acquire` for the same key (a caller that is not the router, as the registry and the multitool are) with a stub loader cause one load, and the model stays resident until both release it.
- [ ] Add a test file that imports both modules and uses `ModelPool`, and it compiles.
- [ ] Add a test: a direct `pool.acquire` of a new key (a caller that is not the router), started while a router resolve runs, starts its load only after the router's admission job ends. The router's fit then uses a correct footprint.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo