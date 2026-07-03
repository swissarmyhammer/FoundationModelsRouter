---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Add smoke tests for SystemMachineProbe (live MachineProbe)
---
Sources/FoundationModelsRouter/Sizing/HostProfile.swift:87-116

Coverage: 44.4% (16/36 lines) — the whole `SystemMachineProbe` struct is 0% covered; only the pure `HostProfile` type (init, `budget(headroomReserve:)`) is tested.

Uncovered lines: 87-91 (`chip`), 94-96 (`totalRAM`), 100-103 (`recommendedMaxWorkingSetSize`), 109-116 (`sysctlString`)

`MachineProbe` exists specifically so `HostProfile`'s budget math is testable with a stub — but the *live* `SystemMachineProbe` implementation itself has zero tests. Unlike `LiveModelLoader` (which needs real network + GPU + multi-GB downloads and is intentionally left to the gated milestone-7 integration suite), `SystemMachineProbe` only reads local host facts (`sysctlbyname`, `ProcessInfo.physicalMemory`, `MTLCreateSystemDefaultDevice()`) — no network, no model weights. It can run as an ordinary unit test on the CI Mac runner.

Add a smoke-test suite (e.g. `Tests/FoundationModelsRouterTests/HostProfileTests.swift` if it doesn't already cover only the pure type) asserting real-machine invariants:
- `SystemMachineProbe().totalRAM > 0`
- `SystemMachineProbe().chip` is non-empty (exercises the `sysctlString` success path and the `machdep.cpu.brand_string` / `hw.model` fallback chain)
- `SystemMachineProbe().recommendedMaxWorkingSetSize >= 0` (0 is valid when no Metal device, per the doc comment)
- Constructing `HostProfile(probe: SystemMachineProbe())` succeeds and its fields match the probe's own values

Don't assert exact values (machine-dependent) — assert the invariants the doc comments already promise.