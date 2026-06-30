---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: todo
position_ordinal: '8380'
title: Host profiling + budget + disk cache (milestone 1)
---
## What
Measure the machine once and compute the RAM budget; cache to disk keyed by `(chip, totalRAM)`. Plan "Host profile & budget (milestone 1)".

- `Sources/FoundationModelsRouter/Sizing/HostProfile.swift`:
  - `struct HostProfile: Sendable, Codable { chip: String; totalRAM: Int64; recommendedMaxWorkingSetSize: Int64 }`.
  - `budget(headroomReserve:) -> Int64 = min(recommendedMaxWorkingSetSize, totalRAM - headroomReserve)`.
  - A `MachineProbe` protocol abstracting the OS reads so tests inject values:
    - `totalRAM` via `ProcessInfo.physicalMemory` (≡ sysctl `hw.memsize`).
    - `recommendedMaxWorkingSetSize` via `MTLDevice.recommendedMaxWorkingSetSize`.
    - `chip` (e.g. `sysctlbyname("machdep.cpu.brand_string")` or `hw.model`).
  - Live implementation `SystemMachineProbe`; test implementation injects fixed values.
- `Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift`:
  - Read/write the profile as JSON under the configured `cacheDir`, keyed by `(chip, totalRAM)`. Disposable cache (not the recordings dir).

## Acceptance Criteria
- [ ] Given injected `(totalRAM, recommendedMaxWorkingSetSize)`, `budget` = `min(recommended, totalRAM - headroomReserve)` exactly (e.g. 128 GB RAM, 96 GB recommended, 4 GB reserve → 96 GB; 32 GB RAM, 24 GB recommended → 24 GB).
- [ ] Profile persists to and reloads from the cache dir, identical after round-trip.
- [ ] Cache key distinguishes different `(chip, totalRAM)` machines.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/HostProfileTests.swift` (Swift Testing): budget computation with multiple injected machine specs incl. the boundary where `totalRAM - reserve < recommended`; cache write/read round-trip in a temp dir; key separation.
- [ ] Run `swift test --filter HostProfileTests` — all pass.

## Workflow
- Use `/tdd` — write failing budget + cache tests with injected specs first.