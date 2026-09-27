---
assignees:
- claude-code
depends_on:
- 01M3FNBKR2347W659AXFJVZKGM
position_column: todo
position_ordinal: a080
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