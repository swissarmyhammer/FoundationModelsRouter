---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m137ayw0a1jaxjk09f5qvfr6
  text: |
    Picked up. Research:

    - `HostProfileCache` has exactly 4 reference sites: its own file, `HostProfile.swift` doc comment, `Router.swift` (property + init + `hostBudget()`), and `HostProfileTests.swift` (3 cache tests + `makeCache` helper).
    - `hostBudget()` reads `probe.chip` and `probe.totalRAM` to build the cache key, then loads. So a cache hit still costs 2 of the 3 probe reads and saves only `recommendedMaxWorkingSetSize`. The key holds chip and RAM constant across an OS update, so a changed working set returns stale.
    - The budget a resolve used is observable through `ResolutionFailure.budgetBytes` (Sources/FoundationModelsRouter/Resolution/SlotResolution.swift). That is the seam for the stale-budget regression test: two resolves that both fail, with the probed working set changed between them.
    - New tests go in `Tests/FoundationModelsRouterTests/ResolveTests.swift`, which already owns the Router+stub fixtures (`StubProbe`, `StubMetadataSource`, `StubModelLoader`, `makeTempDir`, the shared `profile`). `HostProfileTests.swift` has none of that wiring.
    - A mutable probe needs reference semantics so the test and the router read one object. `Mutex` (Synchronization) is the prevailing guard in this package.
  timestamp: 2026-08-28T03:41:39.584337+00:00
- actor: claude-code
  id: 01m137kx79xtqz66qf5hj072sf
  text: |
    TDD RED, recorded before any source change. `swift test --filter 'eachResolveReadsTheHostBudgetAfresh|resolveWritesNoHostProfileFile'` gave 2 failures, each for the defect the card names:

    ```
    ✘ "a later resolve prices against the host's new working set, not the one the first resolve read"
      ↳ after.budgetBytes → 1000
      ↳ Self.workingSetAfterOSUpdate → 2000
    ✘ "resolve leaves no host-profile file in the cache directory"
      ↳ hostProfileFiles → ["host-profile-a64cfb76...189ec.json"]
    ```

    The first is the stale budget itself: the cache key `(chip, totalRAM)` cannot see the working set move, so the second resolve priced against the first resolve's number.

    Then GREEN. Notes for the next reader:

    - The new tests went in `ResolveTests.swift`, not `HostProfileTests.swift`. `ResolveTests` already owns every fixture a resolve needs (`StubProbe`, `StubMetadataSource`, `StubModelLoader`, `makeTempDir`, the shared `profile`); putting them in `HostProfileTests` would have copied all of it.
    - The mutable probe is `ChangingWorkingSetProbe`, a `final class` holding a `Mutex<Int64>`. It is a reference type on purpose — the test and the router must read one object — and `recommendedMaxWorkingSetSize` is a get/set computed property, so the test writes it as a plain assignment and `MachineProbe`'s get-only requirement is still met.
    - Both resolves in that test fail on purpose. A failed resolve acquires nothing, so the pool stays empty and `effectiveBudget == totalBudget`; the assertion reads a clean machine budget rather than a budget less some resident footprint.
    - `makeTempDir` in `HostProfileTests.swift` had to go too: `makeCache` was its only caller, so removing the cache tests left it dead.
    - Two doc comments beyond the ones the card lists also named the cache and were corrected: the `Router` actor's own header ("holds the host-profile and repo-metadata caches") and `hostBudget()`'s summary ("measuring and caching the host profile").
  timestamp: 2026-08-28T03:46:32.809362+00:00
- actor: claude-code
  id: 01m137m6vdk58r2prqvxc2c4ms
  text: |
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Sizing/HostProfile.swift, Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift (deleted), Tests/FoundationModelsRouterTests/HostProfileTests.swift, Tests/FoundationModelsRouterTests/ResolveTests.swift (+144 / -156). `swift build` complete, exit 0. `swift test` exit 0: 1068 tests in 108 suites passed with 2 known issues, plus 83 eval tests in 10 suites passed. Zero failures. The count moved 1069 -> 1068 exactly: 3 cache tests removed, 2 regression tests added. `swift build --package-path IntegrationTests --build-tests` complete, exit 0.
    - next: /review
  timestamp: 2026-08-28T03:46:42.669243+00:00
position_column: doing
position_ordinal: '80'
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
- [x] `HostProfileCache` does not exist in the package.
- [x] `hostBudget()` computes its result from a fresh probe read on each call.
- [x] After a `resolve` against a temporary `cacheDir`, that directory contains no file matching `host-profile-*.json`.
- [x] The `HostProfile` doc comments do not mention a cache.

## Tests
- [x] Update `HostProfileTests.swift` as above.
- [x] Add a test with a mutable stub probe: change the probed `recommendedMaxWorkingSetSize` between two `resolve` calls against the same router and assert the budget behind the second resolve reflects the new value. This is the regression test for the stale-budget defect.
- [x] Add a test that resolves against a temporary `cacheDir` and asserts no `host-profile-*.json` file exists in it afterwards.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #cleanup