---
assignees:
- claude-code
position_column: todo
position_ordinal: aa80
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