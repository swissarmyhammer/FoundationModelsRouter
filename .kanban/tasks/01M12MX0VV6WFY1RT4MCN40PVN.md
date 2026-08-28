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
- In `Sources/FoundationModelsRouter/Router.swift`: remove the `hostProfileCache` property (line 138) and its initialization (line 212). In `effectiveBudget` (lines 474-482), replace the load-or-probe-and-save block with a direct `HostProfile(probe: probe)`.
- In `Sources/FoundationModelsRouter/Sizing/HostProfile.swift`: update the doc comments that refer to the cache and to a "one-time measurement" (lines 22-28). The profile is now a per-resolve read.
- Keep the router's `cacheDir`; `RepoMetadataReader` still uses it.
- In `Tests/FoundationModelsRouterTests/HostProfileTests.swift`: remove the cache tests (save/load round trip, overwrite, distinct keys, and the `makeCache` helper). Keep the probe, budget, and Codable tests.
- Search the package for other `HostProfileCache` references and remove them.

## Acceptance Criteria
- [ ] `HostProfileCache` does not exist in the package.
- [ ] `Router.resolve` computes its budget from a fresh probe read on each call.
- [ ] No file named `host-profile-*.json` is ever written.
- [ ] The `HostProfile` doc comments do not mention a cache.

## Tests
- [ ] Update `HostProfileTests.swift` as above.
- [ ] Add one test that shows `effectiveBudget` reflects a changed probe value on the next resolve, with a mutable stub probe. This is the regression test for the stale-budget defect.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #cleanup