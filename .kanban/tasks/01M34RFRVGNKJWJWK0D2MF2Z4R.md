---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
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