---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: todo
position_ordinal: '8280'
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