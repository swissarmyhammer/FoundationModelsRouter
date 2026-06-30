---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: todo
position_ordinal: '9380'
title: Replace hand-rolled ULID with yaslab/ULID.swift library
---
## What
Per user decision (2026-06-30), swap the in-house `Core/ULID.swift` for the maintained **yaslab/ULID.swift** library, keeping our module's `ULID` API surface intact so already-`done` and future tasks compile unchanged.

Verified library facts: package `https://github.com/yaslab/ULID.swift.git`, product/module `ULID`, latest `1.3.1`, MIT, swift-tools 5.9. Type conforms to `Hashable, Equatable, Comparable, CustomStringConvertible, Sendable, Codable` (Codable = 26-char Crockford base32 string). Deterministic init: `init<T: RandomNumberGenerator>(timestamp:generator:)` and `init?(timestamp:randomPartData:)`.

- `Package.swift`: add `.package(url: "https://github.com/yaslab/ULID.swift.git", from: "1.3.1")` and add product `"ULID"` to the `FoundationModelsRouter` target deps. Reuse the existing top-level constant style if natural. Commit the updated `Package.resolved` (pins the new dep).
- `Sources/FoundationModelsRouter/Core/ULID.swift`: delete the hand-rolled implementation and instead re-export the library type plus a thin compatibility shim so our design's API holds:
  - Re-export: `@_exported import ULID` (or a module-qualified `public typealias`).
  - Shim extension preserving our planned call sites: `static func generate() -> ULID { ULID() }`, `init?(_ s: String) { self.init(ulidString: s) }`. Confirm `description` (via `CustomStringConvertible`) returns the 26-char string and `Comparable` orders by timestamp — both already true in the library, so no reimplementation.
  - Net effect: downstream code that uses `ULID.generate()`, `ULID(someString)`, `String(describing: ulid)`, `Comparable`, `Codable` keeps working.
- `Tests/FoundationModelsRouterTests/ULIDTests.swift`: drop the exhaustive base32/spec/overflow tests (the library owns that correctness). Keep a SMALL smoke suite asserting our shim contract only: `ULID.generate()` → 26-char string that round-trips through `ULID(_:)`; timestamp ordering via the deterministic `init(timestamp:generator:)`; Codable round-trip.

## Acceptance Criteria
- [ ] `swift build` resolves yaslab/ULID.swift @ 1.3.1 and compiles; `Package.resolved` pins it.
- [ ] Our module still exposes `ULID` with `.generate()`, string init `ULID(_:)`, 26-char `description`, `Comparable` (timestamp-ordered), `Codable`, `Sendable` — the design API is unchanged (no downstream task needs editing).
- [ ] The hand-rolled encode/decode/generation code is gone from `Core/ULID.swift`; correctness now comes from the library.
- [ ] `swift test` (full suite) is green.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ULIDTests.swift` (Swift Testing) — shim smoke: generate→26-char→round-trip; deterministic timestamp ordering; Codable round-trip.
- [ ] Run `swift test` (env `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — all pass.

## Workflow
- Use `/tdd` — write the shim smoke tests first (against the intended re-exported API), then wire the dependency + shim to green.