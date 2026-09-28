---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3j557py834r2cabxckmtwck
  text: |-
    Research and decisions.
    - Extras: `swift package update FoundationModelsExtras` resolves the root at ea9dc99 (checkout `git log -1` = ea9dc99). `IntegrationTests/Package.resolved` is set to ea9dc99230f8be7d2f60f81b2903714c5e667d37. The router and the IntegrationTests build with no error at ea9dc99; the `BackgroundTool.mount(for:)`, `@Operation(mount:)` and `GenerationQueue` changes needed no router change.
    - The fix (c7691c0): `ModelPool.release` puts the eviction job in the admission queue under the pool lock (`admissions.enqueue`). The eviction job still runs later. Thus a resolve (an admission job) after the drop sees the freed bytes, but a synchronous `footprint` / `residentModelCount` read right after the drop can still show the model. So the tests that read the footprint after a drop still need an order point. The stream wait (`footprints` until a condition) is not necessary now: one admission job that reads the footprint is sufficient. `ModelPool.settle(until:)` is removed; the unit tests use `ModelPool.admittedFootprint` (`try await admit { $0.footprint }`) in `Helpers/ResidencyDrop.swift`. The IntegrationTests package does not import Extras, so it cannot name `ModelPoolFootprint`: its helper is `admittedResidentModelCount` (file renamed to `Support/AdmittedResidentModelCount.swift`).
    - Restored test: "a resolve after the last reference to a profile is dropped sees the freed bytes at once", with no wait between the drop and the resolve.
    - Failing first on the old Extras: NOT shown. I pinned the root to f4bd503 and ran the restored test 20 times alone and the 6 pool suites 6 times with `--parallel --num-workers 8`: all passed. The detached task of f4bd503 almost always submits the eviction job before the resolve submits its admission job, and a test has no signal that can delay a detached task. So the old order race cannot be made deterministic from a router test.
    - Discovery: in one earlier run on f4bd503 the restored test hung. `sample` showed `Router.deinit` -> `PromptCacheSizing.deinit` -> `footprints` `onTermination` waiting for the pool lock, while the eviction job was in `State.publish()` (yield under the pool lock) waiting for a different lock. The same code is in ea9dc99. 25 single runs and 10 parallel suite runs at ea9dc99 did not hang. Recorded as a new task 01M3J54T474YS9R1WB7NK18BKS (Extras, cross-repo).
    - Docs: the late-eviction notes (^adn17rg) in `PromptCacheSizing`, `model-pool.md` §2.9, §2.10, §3 and `README.md` are no longer true and are rewritten: the eviction job is in the queue before each later admission job; the resize for the freed weights comes after the jobs before the eviction job. `model-pool.md` names Extras revision ea9dc99.
  timestamp: 2026-09-27T19:23:35.006047+00:00
- actor: claude-code
  id: 01m3j84d02evx1fn1exsqdyz3w
  text: |-
    ### implement — changed
    - evidence: 13 files — Tests/FoundationModelsRouterTests/Helpers/ResidencyDrop.swift (`settle(until:)` removed; `ModelPool.admittedFootprint` added), PooledResidencyTests.swift (restored test "a resolve after the last reference to a profile is dropped sees the freed bytes at once", no wait), CrossRouterResidencyTests.swift, ExtrasPoolResolveTests.swift, ProfileLifecycleTests.swift, ToolSharedProfileTests.swift, SlotPoolLoaderTests.swift (stream waits replaced by one admission read), IntegrationTests .../Support/ModelPoolEviction.swift renamed to AdmittedResidentModelCount.swift (`admittedResidentModelCount`), CrossRouterPoolIntegrationTests.swift, PromptCacheBudgetIntegrationTests.swift, Sources/FoundationModelsRouter/Sizing/PromptCacheSizing.swift (doc), model-pool.md, README.md.
    - Extras: the coordinator changed the target to b189086 (fix bc47b26). Root `Package.resolved` and `IntegrationTests/Package.resolved` both resolve at b1890867be20ac37d824a1dc7c1085883e94d664 (checkout `git log -1` = b189086).
    - Verification: 10 pool suites (PromptCacheBudget, ExtrasPoolResolve, PooledResidency, CrossRouterResidency, ResolveCancellation, ProfileLifecycle, SlotPoolLoader, ToolSharedProfile, ModelPoolName, OwningProfile) 10 times with `--parallel --num-workers 8` at ea9dc99 — 67 tests in 10 suites passed each time; the restored test 25 times alone at ea9dc99 — passed each time. `swift build --build-tests --package-path IntegrationTests` — Build complete, no error.
    - next: /test
  timestamp: 2026-09-27T20:15:33.378038+00:00
- actor: claude-code
  id: 01m3j84jpv47wphbgf977r0n5z
  text: |-
    ### test — stuck
    - evidence: `swift package clean && swift build --build-tests` at Extras b189086 — Build complete, no source warning (only the Cmlx C++17 warnings of the mlx-swift dependency and the SwiftPM cache messages). `swift test --skip-build` hung in 2 of 2 full runs (one at ea9dc99, one at b189086); no test count, because the run did not end. `sample` shows a lock-order inversion in FoundationModelsExtras: `PromptCacheSizing.deinit` -> `footprintsTask.cancel()` holds the status lock of the task and its `footprints` `onTermination` waits for the pool lock, while the eviction job holds the pool lock in `State.publish()` and its `yield` waits for the status lock of the same task. Hung tests: `SessionTreeRestorationToolWiringTests.restoredRootWrapsNonStringOutputToolInItsOwnBindingLayer`, `SessionTreeRestorationTests.restoreReportsRecordedToolsTheCallerDidNotSupply` (not changed by this task). Full evidence: task 01M3J54T474YS9R1WB7NK18BKS.
    - Blocker: the defect is in FoundationModelsExtras (`ModelPool.State.publish()` yields under the pool lock; `onTermination` takes the pool lock). The eviction-order fix c7691c0 makes the eviction run sooner, so it overlaps a router release more often. A person must decide: an Extras fix (task 01M3J54T474YS9R1WB7NK18BKS), or a router change to how `PromptCacheSizing` stops its footprints task. The work of this task is in the working tree, not committed.
    - next: a person decides; then /test again.
  timestamp: 2026-09-27T20:15:39.227869+00:00
- actor: claude-code
  id: 01m3j84pd6mkwzvj95ment2p8r
  text: |-
    ### finish iteration 1 — test stuck
    - implement: changed — ResidencyDrop.swift (`settle(until:)` removed, `admittedFootprint`), PooledResidencyTests.swift (restored test with no wait), CrossRouterResidencyTests.swift, ExtrasPoolResolveTests.swift, ProfileLifecycleTests.swift, ToolSharedProfileTests.swift, SlotPoolLoaderTests.swift, IntegrationTests Support/AdmittedResidentModelCount.swift (renamed), CrossRouterPoolIntegrationTests.swift, PromptCacheBudgetIntegrationTests.swift, PromptCacheSizing.swift (doc), model-pool.md, README.md. Extras b189086 in both Package.resolved files.
    - test: stuck — clean build with no source warning; full `swift test` hung 2 of 2 runs on an Extras lock-order inversion (footprints `onTermination` vs `State.publish()`), task 01M3J54T474YS9R1WB7NK18BKS.
    - commit: none (test not green).
    - review: not run.
  timestamp: 2026-09-27T20:15:43.014773+00:00
- actor: claude-code
  id: 01m3m0mw2hpbxwzbngsjwb1nc6
  text: |-
    ### test — green
    - evidence: Extras at 4a733cd (includes fix 644b897 "fix(modelpool): yield footprints outside the state lock") in the root `Package.resolved`, `IntegrationTests/Package.resolved` and both checkouts. `swift package clean && swift build --build-tests` — Build complete, no source warning (only Cmlx C++17 warnings in the mlx-swift checkout, "missing creator" and the SwiftPM manifest cache "disk I/O error" messages). Full `swift test --skip-build` 4 times in a row, no hang: each run 1464 tests in 177 suites passed (2 known issues, intentional `withKnownIssue`), 17 tests in 8 suites passed, 19 tests in 3 suites passed. 10 pool suites (PromptCacheBudget, ExtrasPoolResolve, PooledResidency, CrossRouterResidency, ResolveCancellation, ProfileLifecycle, SlotPoolLoader, ToolSharedProfile, ModelPoolName, OwningProfile) with `--parallel --num-workers 8`, 10 times — 67 tests in 10 suites passed each time. `swift build --build-tests --package-path IntegrationTests` — Build complete. `model-pool.md` now names Extras revision 4a733cd.
    - next: /commit
  timestamp: 2026-09-28T12:43:13.361119+00:00
position_column: doing
position_ordinal: '80'
title: 'Router: remove the eviction waits from the pool tests after the Extras eviction-order fix'
---
## What
Found in task 01M3FNJS6J7KGAJJ5WFEST00WA (^est00wa). In FoundationModelsExtras at f4bd503, the last `ModelHold` release submits the eviction job from `Task.detached` (`ModelPool.swift:149`). Thus an admission job that a caller submits after the last release can run BEFORE the eviction job, and it sees the freed model as resident. A `Router.resolve` that starts at once after the last reference to a profile is dropped can then fail a tight budget. The old router pool gave this guarantee (`drainPendingReleases()` before each measurement).

The fix is in Extras (sent to the Extras session on 2026-09-27): the eviction job enters the admission queue synchronously in the release. This router task is blocked until that fix is on Extras `main`.

Router part:
- Update `Package.resolved` (ignored by git) to the Extras commit with the fix: `swift package update FoundationModelsExtras`, and set `IntegrationTests/Package.resolved` to the same commit.
- Remove the waits on the `footprints` stream that router tests use before such a resolve (`ModelPool.settle(until:)` in `Tests/FoundationModelsRouterTests/Helpers/ResidencyDrop.swift`) where the fix makes them unnecessary.
- Restore the router test "a resolve after the last reference to a profile is dropped sees the freed bytes at once" (`PooledResidencyTests`) with no wait.

## Acceptance Criteria
- [ ] A router resolve that starts at once after the drop of the last reference sees the freed bytes in its first measurement, with no wait in the test.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] `PooledResidencyTests` passes with parallel repetitions (`--parallel --num-workers 8`, 10 times).
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#cross-repo #pool-eviction-order #model-pool