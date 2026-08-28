---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Remove HostProfileCache and probe the host on each resolve
---
## What

Delete the on-disk host-profile cache. The cache saves one Metal property read, and its key derivation reads two of the three probed values. A cache hit costs more than the probe. The cache is also the one path that can return a stale budget after an OS update.

- Delete `Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift`.
- In `Sources/FoundationModelsRouter/Router.swift`: remove the `hostProfileCache` property (line 138) and its initialization (line 212). The load-or-probe-and-save block at lines 474-482 lives inside `private func hostBudget() -> Int64` (declared at line 472). Replace that block with a direct `HostProfile(probe: probe)`. Note `effectiveBudget` is an unrelated local constant inside `resolve` at line 241; do not change it.
- In `Sources/FoundationModelsRouter/Sizing/HostProfile.swift`: update the doc comments that refer to the cache and to a "one-time measurement" (lines 22-28). The profile is now a per-resolve read.
- Keep the router's `cacheDir`; `RepoMetadataReader` still uses it.
- In `Tests/FoundationModelsRouterTests/HostProfileTests.swift`: remove the cache tests (save/load round trip, overwrite, distinct keys, and the `makeCache` helper). Keep the probe, budget, and Codable tests.
- Search the package for other `HostProfileCache` references and remove them.

## Acceptance Criteria
- [ ] `HostProfileCache` does not exist in the package.
- [ ] `hostBudget()` computes its result from a fresh probe read on each call.
- [ ] After a `resolve` against a temporary `cacheDir`, that directory contains no file matching `host-profile-*.json`.
- [ ] The `HostProfile` doc comments do not mention a cache.

## Tests
- [ ] Update `HostProfileTests.swift` as above.
- [ ] Add a test with a mutable stub probe: change the probed `recommendedMaxWorkingSetSize` between two `resolve` calls against the same router and assert the budget behind the second resolve reflects the new value. This is the regression test for the stale-budget defect.
- [ ] Add a test that resolves against a temporary `cacheDir` and asserts no `host-profile-*.json` file exists in it afterwards.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #cleanup