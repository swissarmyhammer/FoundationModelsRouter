---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: todo
position_ordinal: '8180'
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