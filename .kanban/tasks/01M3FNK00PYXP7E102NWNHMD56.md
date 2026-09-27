---
assignees:
- claude-code
depends_on:
- 01M3FNBKR2347W659AXFJVZKGM
position_column: todo
position_ordinal: a180
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
- Use `/tdd` — write failing tests first, then implement to make them pass.