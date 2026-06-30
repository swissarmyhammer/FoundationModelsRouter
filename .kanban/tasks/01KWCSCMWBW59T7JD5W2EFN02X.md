---
comments:
- actor: wballard
  id: 01kwcsvg3apeg6xm44f2zev4jb
  text: |-
    Implemented via TDD. Replaced hand-rolled Core/ULID.swift with yaslab/ULID.swift (resolved & pinned at 1.3.1 in Package.resolved). Package.swift adds the dependency via a top-level `ulidPackage`/`ulidProduct` constant style matching the existing manifest, and the product is on the FoundationModelsRouter target deps. Core/ULID.swift is now `@_exported import ULID` plus a thin shim: `static func generate() -> ULID { ULID() }` and `init?(_ string:) { self.init(ulidString:) }`. Sendable/Hashable/Comparable/Codable/CustomStringConvertible all come from the library, no reimplementation. Tests trimmed to a 3-test smoke suite (generate->26-char round-trip via ULID(_:), deterministic timestamp ordering via init(timestamp:generator:), Codable round-trip). No downstream code referenced ULID yet (grep confirmed), so no callers needed editing. swift build + swift test both green (DEVELOPER_DIR=Xcode-beta): 9 tests/3 suites + gated integration suite all pass.

    Note: the MCP `files` write op silently no-ops in this environment (returns stale content); wrote files via shell heredoc instead.
  timestamp: 2026-06-30T17:39:56.650660+00:00
- actor: wballard
  id: 01kwctf939dcym1haqv9hsvyrs
  text: 'Addressed open review finding (case-insensitive ULID parse not covered). Added a complete lowercase round-trip to roundTrip() in Tests/FoundationModelsRouterTests/ULIDTests.swift covering both directions: decode (`#expect(ULID(lowercase) == ulid)`) and re-encode to canonical uppercase (`#expect(ULID(lowercase)?.description == text)`), where `lowercase = text.lowercased()`. Library accepts lowercase per Crockford spec — no shim change needed; Core/ULID.swift untouched. `swift test --filter ULIDTests` → 3/3 green. Finding flipped to [x]. Task stays in doing for /review.'
  timestamp: 2026-06-30T17:50:44.841301+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: done
position_ordinal: '8380'
title: Replace hand-rolled ULID with yaslab/ULID.swift library
---
## What
Per user decision (2026-06-30), swap the in-house `Core/ULID.swift` for the maintained **yaslab/ULID.swift** library, keeping our module's `ULID` API surface intact so already-`done` and future tasks compile unchanged.

Verified library facts: package `https://github.com/yaslab/ULID.swift.git`, product/module `ULID`, latest `1.3.1`, MIT, swift-tools 5.9. Type conforms to `Hashable, Equatable, Comparable, CustomStringConvertible, Sendable, Codable` (Codable = 26-char Crockford base32 string). Deterministic init: `init<T: RandomNumberGenerator>(timestamp:generator:)` and `init?(timestamp:randomPartData:)`.

- `Package.swift`: add `.package(url: \"https://github.com/yaslab/ULID.swift.git\", from: \"1.3.1\")` and add product `\"ULID\"` to the `FoundationModelsRouter` target deps. Reuse the existing top-level constant style if natural. Commit the updated `Package.resolved` (pins the new dep).
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

## Review Findings (2026-06-30 12:44)

- [x] `Sources/FoundationModelsRouter/Core/ULID.swift:28` — The new init?(_ string: String) parses ULID strings using a case-insensitive format (Crockford base32 per spec), but no test verifies lowercase input is accepted. roundTrip() only exercises the canonical uppercase form, leaving the format's case-insensitive contract unverified. Add one assertion in roundTrip() verifying lowercase round-trips identically—e.g., #expect(ULID(ulid.description.lowercased()) == ulid). RESOLVED (2026-06-30): added a full lowercase round-trip in roundTrip() covering both directions — `#expect(ULID(lowercase) == ulid)` (decode) and `#expect(ULID(lowercase)?.description == text)` (re-encode to canonical uppercase). Test-only change; shim untouched. `swift test --filter ULIDTests` → 3/3 green.