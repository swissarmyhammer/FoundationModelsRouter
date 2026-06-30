---
comments:
- actor: wballard
  id: 01kwcmcsmgrd8ttgyrx8eyrqp4
  text: |-
    Implemented ULID via TDD. Wrote Tests/FoundationModelsRouterTests/ULIDTests.swift first (RED: "cannot find 'ULID' in scope"), then Sources/FoundationModelsRouter/Core/ULID.swift.

    Design notes:
    - Internal representation is a single UInt128 `value` (timestamp in high 48 bits, randomness in low 80). Available because the package targets Swift 6.1 / macOS 27. UInt128 gives Comparable/Hashable/Sendable for free and makes encode/decode a clean big-integer base32 loop.
    - Encoding treats the 128-bit value as a 130-bit space (2 high padding bits) and emits 26 Crockford chars MSB-first — algebraically identical to the canonical ULID time/random split. Verified against the spec vector: timestamp 1469918176385 -> first 10 chars "01ARYZ6S41".
    - Decode rejects wrong length, non-alphabet chars, and a first char > '7' (would overflow 128 bits). Crockford-lenient on input: lowercase accepted, I/L->1, O->0; U and symbols rejected.
    - generate(timestamp:) defaults to currentMilliseconds() but the timestamp is injectable, which the ordering tests use for determinism.
    - Pure: only imports Foundation, no MLX.

    Results (with DEVELOPER_DIR=Xcode-beta): `swift build` green; `swift test --filter ULIDTests` 6/6 pass; full `swift test` green (Bootstrap + ULID, integration skipped). Leaving in doing for review.
  timestamp: 2026-06-30T16:04:32.016414+00:00
- actor: wballard
  id: 01kwcmk4zgn79xbefbcxs4g3w7
  text: 'Adversarial double-check returned PASS (verified build/tests, full-range round-trip, overflow boundary, Comparable/bit-layout, Codable, rejection completeness). Acted on its one non-blocking suggestion: pinned the canonical ULID spec vector (1469918176385 ms -> prefix "01ARYZ6S41") as a test so a self-consistent-but-non-standard encoding would be caught. swift test --filter ULIDTests now 7/7 green. Task stays in doing for /review.'
  timestamp: 2026-06-30T16:08:00.240672+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: doing
position_ordinal: '80'
title: ULID value type (time-sortable id)
---
## What
A 128-bit, lexicographically time-sortable identifier (Crockford base32), used as the Router's recording root id and each session's span id (see plan "Transcripts & recording").

- `Sources/FoundationModelsRouter/Core/ULID.swift`:
  - `struct ULID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible`.
  - `static func generate() -> ULID` — 48-bit ms timestamp + 80-bit randomness.
  - 26-char Crockford base32 encode/decode (`description` / `init?(_ string: String)`).
  - `Comparable` so ids sort chronologically by construction (timestamp prefix); ties broken by random bits.
  - `Codable` as the canonical 26-char string.
- Pure; no dependency on MLX.

## Acceptance Criteria
- [ ] `ULID.generate()` yields a valid 26-char Crockford base32 string that round-trips through `init?(_:)`.
- [ ] Two ULIDs generated in timestamp order compare `<` in the same order (use injectable/monotonic clock or generate-with-timestamp helper for determinism).
- [ ] `Codable` encodes to the 26-char string and decodes back equal.
- [ ] Invalid strings (wrong length, non-base32 chars) fail `init?` returning nil.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ULIDTests.swift` (Swift Testing): round-trip, ordering by timestamp, base32 alphabet rejection, Codable round-trip.
- [ ] Run `swift test --filter ULIDTests` — all pass.

## Workflow
- Use `/tdd` — write failing encode/decode/ordering tests first.