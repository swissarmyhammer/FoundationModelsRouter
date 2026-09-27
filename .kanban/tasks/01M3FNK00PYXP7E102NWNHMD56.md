---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hzdanj50akktqfr98r4369
  text: |-
    Research (Extras at f4bd503). Facts from the code:
    - `pool.footprints` makes a new `AsyncStream` for each call. It yields the current value under the pool lock, then each change. `onTermination` removes the continuation, so a cancelled reader leaves nothing in the pool. The stream does not keep the pool (weak self).
    - `load` publishes `loadingBytes = footprintBytes` before `loader.load`, then publishes the resident entry with `loadingBytes = 0`. A failed load publishes `loadingBytes = 0`. A release publishes at once; the eviction publishes after `evict`, from a job that a detached task submits (known gap ^adn17rg).
    - `ModelPoolFootprint.totalBytes` = the resident bytes plus `loadingBytes`.
    Design:
    - New `Sizing/PromptCacheSizing.swift`: each router makes one `PromptCacheSizing` (its loader, its pool, its probe). It starts one task that reads `pool.footprints`; `deinit` cancels the task, so the task ends when the router is released.
    - All resizes of one router go through one serial gate (`AsyncSemaphore(value: 1)`), and each resize reads the footprint of the pool NOW (the stream value is only the signal). Thus a late stream value can not send an old budget after the router's own resize.
    - The router's own acquire (inside its admission job) calls `withBudget(adding:_:)`: it resizes with the added bytes, runs the acquire, and then resizes with no added bytes (on success and on failure). While this runs, the stream task does not resize, because the added bytes and the `loadingBytes` of the same load would count two times. A release during the router's load thus resizes only when the acquire ends (conservative: the budget is small for that time).
    - `Router.acquire` loses its `workingSetBytes` parameter: the sizing reads the working set from the probe for each resize.
  timestamp: 2026-09-27T17:43:08.722559+00:00
- actor: claude-code
  id: 01m3j1jkmhw68722mha2zb2n5x
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Sizing/PromptCacheSizing.swift (new: `PromptCacheSizing` with its `footprintsTask`, cancelled in `deinit`; `withBudget(adding:isolation:_:)`; private `PromptCacheResizer` with one serial gate), Sources/FoundationModelsRouter/Sizing/PromptCacheBudget.swift (doc), Sources/FoundationModelsRouter/Router.swift (`promptCacheSizing`, made in `init`; `acquire` runs inside `withBudget`; the `workingSetBytes` parameter of `acquireSlots` and `acquire` is removed), Tests/FoundationModelsRouterTests/PromptCacheBudgetTests.swift (tests on the stream; new tests: a load by a direct caller, two routers on one pool, the task ends with the router), model-pool.md (section 2.10 and section 3).
    - What did not work first: the direct-caller test hung, because the `Task` that returned the `ModelHold` kept the hold in its result, so the release never came. The task now keeps the hold until a semaphore opens, and returns only the key. The budget wait of the test stub now ends on cancellation, so the suite time limit can stop a hang.
    - Verification: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1464 tests in 177 suites passed (2 known issues that two tests expect), plus 17 tests in 8 suites and 19 tests in 3 suites; `PromptCacheBudgetTests` — 14 tests passed; 10 suites (PromptCacheBudget, ExtrasPoolResolve, PooledResidency, CrossRouterResidency, ResolveCancellation, ProfileLifecycle, SlotPoolLoader, ToolSharedProfile, ModelPoolName, OwningProfile) 10 times with `--parallel --num-workers 8` — 67 tests passed each time; `swift build --build-tests --package-path IntegrationTests` — Build complete, no error, no warning.
    - next: /test
  timestamp: 2026-09-27T18:20:58.897483+00:00
- actor: claude-code
  id: 01m3j1jyq8kfknm7qms1159bwp
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1464 tests in 177 suites passed (2 known issues that two tests expect), plus 17 tests in 8 suites and 19 tests in 3 suites; no skipped test; `swift build --build-tests --package-path IntegrationTests` — Build complete, no error, no warning; 10 pool, residency and prompt-cache suites 10 times with `--parallel --num-workers 8` — 67 tests passed each time.
    - next: /commit
  timestamp: 2026-09-27T18:21:10.248848+00:00
depends_on:
- 01M3FNBKR2347W659AXFJVZKGM
position_column: doing
position_ordinal: '80'
title: 'Router: resize the prompt cache from the footprints stream of the Extras ModelPool'
---
## What
Decision (user, 2026-09-26): the router uses the process-wide `ModelPool` in the core `FoundationModelsExtras` target. Prompt cache sizing stays in the router.

Blocked by Extras task 01M3FN95AM98RJSTCVQ8G1Z7KE. Its final API (read the task description on the Extras board): `ModelPool` is a `final class`; `pool.footprints` is an `AsyncStream<ModelPoolFootprint>` that gives the current value first and then each change; `ModelPoolFootprint` has `resident: [ModelPoolKey: Int64]`, `loadingBytes` and `totalBytes`; `ModelPoolAdmission` gives `footprint` and `acquire`. There are no observer methods.

Today the router pool AWAITS the resize before it starts a load (`Resolution/ModelPool.swift:255`), so memory for the new weights is free before the load. The stream does not wait. Router decision (2026-09-26):
- For a load that the router starts, keep the strict order: inside its `admit` job (task 01M3FNJS6J7KGAJJ5WFEST00WA), the router resizes its own prompt cache for `admission.footprint` plus the loading bytes of the slot, and only then calls `admission.acquire`. After a failed acquire, it resizes back to the resident footprint.
- For a load that a different caller starts (the registry, the multitool), the router resizes when the `footprints` event with `loadingBytes` arrives. The load takes seconds, so the resize is late only for a very short time. Record this limit in the doc comment of `PromptCacheSizing`.

Steps:
- `Sources/FoundationModelsRouter/Sizing/PromptCacheBudget.swift`: each router starts one task that reads `pool.footprints` and resizes the prompt cache of its own loader for each value (resident bytes plus `loadingBytes`). The task is cancelled when the router is released.
- The pool does not hold `any ModelLoader` for the prompt cache after this task.

This task and task 01M3FNJS6J7KGAJJ5WFEST00WA both change the pool call path. If that task is done first, do this task on top of it.

## Acceptance Criteria
- [ ] A load that the router starts resizes the prompt cache before the loader's `load` runs.
- [ ] A load that a different caller starts causes a resize when its `footprints` value arrives.
- [ ] A failed load causes a resize back to the resident footprint.
- [ ] Two routers on one pool each resize their own prompt cache.
- [ ] The stream task ends when the router is released.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Update the prompt cache tests (tag `prompt-cache`, for example the `PromptCacheSizing` tests) to use the stream.
- [ ] Add a test with a stub loader that records the order of calls: for a router resolve, `configurePromptCache` runs before `load`.
- [ ] Add a test: a direct `pool.acquire` of a new key by a different caller causes a resize of the router's stub loader (wait on a real signal, not the wall clock).
- [ ] Add a test: two routers on one pool each resize their own stub loader.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo #prompt-cache