---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37eyrk01d3f198x6h74gphz
  text: |-
    ### design choices
    - `HostProfile.totalRAM` is deleted. After the change, no code in Sources reads it. `HostProfile.budget()` returns `recommendedMaxWorkingSetSize`.
    - `MachineProbe.totalRAM` and `SystemMachineProbe.totalRAM` stay. They are public API, and the card tells to delete `totalRAM` only from the profile. The `MachineProbe` doc now says that the budget does not use `totalRAM`.
    - `HostProfileTests`: the budget test now builds each profile from a stub probe, with a different `totalRAM` in each case, and asserts `budget() == recommendedMaxWorkingSetSize`. The Codable test uses the new two-field `HostProfile`.
    - `model-pool.md` §2.7 said that each router has "its own probe and headroom". That text now says only "its own probe".
    - No new limit and no new constant are added.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Sizing/HostProfile.swift, Tests/FoundationModelsRouterTests/{HostProfileTests,ResolveTracingTests,ResolveTests,ResolveCancellationTests,CrossRouterResidencyTests,Helpers/ResidencyStubs}.swift, model-pool.md. `rg 'headroomReserve|HeadroomReserve'` finds nothing. `swift test`: Test run with 1323 tests in 149 suites passed (2 known issues, not new); 1 test; 19 tests. IntegrationTests build complete.
    - next: commit, then review.
  timestamp: 2026-09-23T15:43:09.920758+00:00
- actor: claude-code
  id: 01m37f30g9wn1dxv5bxq58ct3e
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on a1bd1e2: 0 findings, 0 confirmed, 0 refuted; 7 files attempted, 0 failed. `model-pool.md` has no matching validator.
    - next: done.

    ### finish iteration 1 — done
    - commits: a1bd1e2 (feat(sizing): delete the headroom reserve; the budget is the Metal working set), then the kanban ledger commit.
    - `swift test`: Test run with 1323 tests in 149 suites passed (2 known issues, not new); Test run with 1 test in 1 suite passed; Test run with 19 tests in 3 suites passed.
    - `swift build --build-tests --package-path IntegrationTests`: build complete.
  timestamp: 2026-09-23T15:45:29.097809+00:00
position_column: done
position_ordinal: fffff380
title: Delete the headroom reserve; the memory budget is Metal's working-set figure
---
## Decision (from the owner, 2026-09-22)

`defaultHeadroomReserveBytes` (4 GiB, `Router.swift:10`) and the `headroomReserve` parameter of `Router.init` (`Router.swift:108`) are an invented allowance and must go. The memory budget the fit runs against is `recommendedMaxWorkingSetSize` alone: the machine's own statement of the GPU working set it backs. No host override for memory slack.

## Why

- The 4 GiB came from commit 9a92ff4 with no reason. Commit 490a0ed only named the literal.
- `recommendedMaxWorkingSetSize` is about 70-75% of RAM on Apple Silicon. `RAM − 4 GiB` wins the `min` only on machines of 16 GB and under, where it stacks a guess on Metal's own allowance. On larger machines it changes nothing.
- Every test passes `headroomReserve: 0` except the one that checks the arithmetic.

## Sites

- `Router.swift:10`: the constant. `:43`: the stored property. `:86, :108, :123`: the `init` parameter, its doc and its assignment. `:521-523` `hostBudget()`: calls `budget(headroomReserve:)`.
- `Sizing/HostProfile.swift:66-74`: `budget(headroomReserve:)` and its doc.
- Tests that pass `headroomReserve: 0`: `ResolveTests.swift:343, 415, 559, 844`, `ResolveTracingTests.swift:204`, `ResolveCancellationTests.swift:133`, `Helpers/ResidencyStubs.swift:294` (and its doc at `:258`), `CrossRouterResidencyTests.swift:13` (doc). `ResolveTracingTests.swift:44` uses the constant. `HostProfileTests.swift:90` tests the arithmetic.

## Do this

1. Delete the constant, the property and the parameter. Delete `totalRAM` from the budget: `HostProfile.budget()` returns `recommendedMaxWorkingSetSize`. Keep `totalRAM` on the profile only if something else reads it; check, and delete it too if nothing does.
2. `hostBudget()` calls `budget()`.
3. Remove every `headroomReserve:` argument in tests. Change `HostProfileTests.swift:90` to assert `budget() == recommendedMaxWorkingSetSize`. Change `ResolveTracingTests.swift:44` to the same. Fix the two doc comments.
4. Do not add any other allowance.

## Acceptance

- `rg 'headroomReserve|HeadroomReserve'` finds nothing.
- A `HostProfile` with `recommendedMaxWorkingSetSize` N gives `budget() == N` for any `totalRAM`.
- All tests pass. #compaction #limits