---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwkyrxt62ps7ava1k4hztxs6
  text: |-
    Implemented: added 4 smoke tests to Tests/FoundationModelsRouterTests/HostProfileTests.swift covering the live SystemMachineProbe (no existing suite for it beyond the pure HostProfile type, confirmed by reading the file first):
    - systemMachineProbeReportsPositiveTotalRAM: totalRAM > 0
    - systemMachineProbeReportsNonEmptyChip: chip non-empty (exercises sysctlString success path / brand_string-then-hw.model fallback)
    - systemMachineProbeReportsNonNegativeWorkingSet: recommendedMaxWorkingSetSize >= 0 (0 valid w/o Metal device)
    - hostProfileFromSystemMachineProbeMatchesProbe: HostProfile(probe: SystemMachineProbe()) fields match the probe's own live values

    No production code changed (Sources/FoundationModelsRouter/Sizing/HostProfile.swift untouched) — only test additions, following existing file's style/conventions (no new helpers needed).

    Verification: `swift test` — full suite green, 136/136 passing + 1 gated integration test correctly skipped (Gated real-model integration (milestone 7)). `swift test --filter HostProfileTests` — 10/10 passing including the 4 new ones. double-check adversarial review returned PASS — confirmed tests exercise the real (non-stubbed) probe and its sysctlbyname/ProcessInfo/MTLCreateSystemDefaultDevice paths, no flakiness risk on the macOS-only CI target, all four task-specified invariants covered exactly.

    Task left in `doing` per /implement contract for /review to pick up.
  timestamp: 2026-07-03T12:20:36.294314+00:00
position_column: done
position_ordinal: 9b80
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