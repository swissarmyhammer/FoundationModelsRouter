---
comments:
- actor: wballard
  id: 01kwctxx0tery7p19xmrr5jgyp
  text: |-
    Implemented milestone 1 (TDD). Added:
    - Sources/FoundationModelsRouter/Sizing/HostProfile.swift — HostProfile (Sendable/Codable/Equatable) with chip/totalRAM/recommendedMaxWorkingSetSize; budget(headroomReserve:) = min(recommended, totalRAM - reserve); MachineProbe protocol; live SystemMachineProbe (ProcessInfo.physicalMemory, MTLCreateSystemDefaultDevice().recommendedMaxWorkingSetSize, sysctl machdep.cpu.brand_string falling back to hw.model).
    - Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift — JSON read/write under configured cacheDir, keyed by (chip,totalRAM) via SHA256-hashed filename (collision-resistant, filesystem-safe); creates dir on save; load returns nil when absent.
    - Tests/FoundationModelsRouterTests/HostProfileTests.swift — probe-copy test, parametrized budget cases incl. boundary totalRAM-reserve<recommended (128/96/4→96, 32/24/4→24, 16/12/8→8, 8/6/4→4), cache round-trip in temp dir, cache key separation across (chip,totalRAM).

    Verified RED first (cannot find type MachineProbe), then GREEN. `swift test --filter HostProfileTests` = 4 tests pass; full `swift test` = 13 tests/4 suites + integration all green. Note: budget arguments array needed an explicit typed static (budgetCases) — inline tuple-arithmetic literal tripped the type-checker timeout. Build env: export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer. Left in doing for review.
  timestamp: 2026-06-30T17:58:43.994375+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: doing
position_ordinal: '80'
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