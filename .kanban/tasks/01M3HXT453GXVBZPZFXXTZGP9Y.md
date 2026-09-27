---
assignees:
- claude-code
position_column: todo
position_ordinal: aa80
title: 'Extras: make an admission job after the last release see the eviction of the model'
---
## What
Found in task 01M3FNJS6J7KGAJJ5WFEST00WA (^est00wa). In FoundationModelsExtras at f4bd503, `ModelPool.release(_:sessionBytes:)` (the `deinit` of the last `ModelHold` of a key) submits the eviction job from `Task.detached`. Thus an admission job that a caller submits after the last release can run BEFORE the eviction job. That job then sees the model as resident (its weights), and a new hold of the same key revives it.

Result for the router: `Router.resolve` runs its measurement in one admission job. A resolve that starts at once after the drop of the last reference to a profile is not sure to see the freed weights, and a tight budget can fail. The old router pool gave this guarantee (`drainPendingReleases()` before each measurement).

Fix in the Extras repo: put the eviction job into the admission queue synchronously in `release` (for example a `GenerationQueue` enqueue that does not wait for the result), so that each admission job that is submitted after the release runs after the eviction. Then remove the waits on the `footprints` stream that router tests use before such a resolve (`ModelPool.settle(until:)` in `Tests/FoundationModelsRouterTests/Helpers/ResidencyDrop.swift`), and restore the router test "a resolve after the last reference to a profile is dropped sees the freed bytes at once" (`PooledResidencyTests`) with no wait.

## Acceptance Criteria
- [ ] An admission job submitted after the last release of a key runs after the eviction job of that key.
- [ ] A router resolve that starts at once after the drop of the last reference sees the freed bytes in its first measurement.

## Tests
- [ ] Extras: a test that releases the last hold and then submits an admission job at once; the job sees no resident model.
- [ ] Router: the test above passes with no wait, with parallel repetitions (`--parallel --num-workers 8`, 10 times).
#model-pool #cross-repo