---
comments:
- actor: wballard
  id: 01kwcp4mr4cr76k7n7ptmdkbq0
  text: 'Implemented core value types TDD-style. Wrote failing CoreTypesTests.swift first (RED: types not in scope), then added four files under Sources/FoundationModelsRouter/Core/: ModelRef.swift (Sendable/Hashable/ExpressibleByStringLiteral/Codable; parses "repo@rev" on first ''@''; singleValueContainer Codable of canonical string form, matching ULID.swift convention), ModelSlot.swift (enum standard/flash/embedding), ProfileDefinition.swift (Sendable struct, public init with context defaulting to defaultContext=8192), JSONValue.swift (Sendable/Equatable/Codable; custom Codable encoding native JSON per case via singleValueContainer). GREEN: swift test --filter CoreTypesTests = 5/5 pass; full suite = 13/13 pass, no regressions, no warnings. Build env DEVELOPER_DIR=Xcode-beta. Left in doing for review.'
  timestamp: 2026-06-30T16:35:02.020127+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: doing
position_ordinal: '80'
title: 'Core value types: ModelRef, ModelSlot, ProfileDefinition, JSONValue'
---
## What
The pure, authored data types from the plan's "Core Types" section. No machine knowledge, no MLX.

- `Sources/FoundationModelsRouter/Core/ModelRef.swift`:
  - `struct ModelRef: Sendable, Hashable, ExpressibleByStringLiteral, Codable` — a HF repo id, optionally revision-pinned (e.g. `"org/repo@rev"`). Parse `repo` + optional `revision`. A bare string literal is a valid `ModelRef`.
- `Sources/FoundationModelsRouter/Core/ModelSlot.swift`:
  - `enum ModelSlot: Sendable, Hashable { case standard, flash, embedding }`.
- `Sources/FoundationModelsRouter/Core/ProfileDefinition.swift`:
  - `struct ProfileDefinition: Sendable` with `name`, `description`, `standard: [ModelRef]`, `flash: [ModelRef]`, `embedding: [ModelRef]`, `var context: Int = 8192` (default 8K working context; scales KV footprint & fit).
- `Sources/FoundationModelsRouter/Core/JSONValue.swift`:
  - `enum JSONValue: Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }` with custom `Codable` for dynamic JSON (runtime-schema guided gen output).

## Acceptance Criteria
- [ ] `let r: ModelRef = "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"` compiles (string-literal); revision-pinned form parses `repo`/`revision`.
- [ ] `ProfileDefinition` initializes with `context` defaulting to 8192.
- [ ] `JSONValue` round-trips arbitrary nested JSON through `JSONEncoder`/`JSONDecoder` equal to the source JSON.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CoreTypesTests.swift` (Swift Testing): ModelRef literal + revision parsing; ProfileDefinition default context; JSONValue Codable round-trip on a nested object/array/scalars document.
- [ ] Run `swift test --filter CoreTypesTests` — all pass.

## Workflow
- Use `/tdd` — write failing parsing/round-trip tests first.