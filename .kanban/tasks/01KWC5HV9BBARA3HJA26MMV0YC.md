---
depends_on:
- 01KWC5GJM72ASQV4GKXSFPKFFG
- 01KWC5C3B35X6N0DYZJYZ044BE
position_column: todo
position_ordinal: '8e80'
title: 'Guided generation: typed + dynamic-JSON response shapes (milestone 8b)'
---
## What
The two higher-level guided response shapes built on the raw layer (milestone 8a). Plan "Guided generation → Three response shapes".

- `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift` (extend `RoutedLLM`):
  - **Typed:** `func respond<T: Generable>(to:generating: T.Type) async throws -> T` — schema is *derived from the `@Generable` type*, generation constrained to it, result **decoded into `T`**. One source of truth.
  - **Dynamic JSON:** `func respond(to:matching jsonSchema: String) async throws -> JSONValue` — for a runtime schema with **no Swift type** (e.g. an MCP tool's `inputSchema`); result is schema-valid and parsed into `JSONValue`, never decoded to a fixed type.
  - Both delegate to the raw `respond(to:following:)` (typed derives a `.jsonSchema` from `T`; dynamic wraps the caller's schema string), then decode.
  - Decoding failures and xgrammar subset rejections surface as the typed `GuidedGenerationError` from milestone 8a.

## Acceptance Criteria
- [ ] `respond(to:generating: SomeGenerable.self)` returns a decoded `T` (real decode asserted in the gated integration suite; unit-assert the derived schema matches the type's shape and the decode path maps raw JSON → `T`).
- [ ] `respond(to:matching: schemaString)` returns a `JSONValue` matching the schema, introspectable dynamically (no fixed Swift type).
- [ ] Malformed/over-spec schemas raise `GuidedGenerationError`, consistent with milestone 8a.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/GuidedShapesTests.swift` (Swift Testing): a sample `@Generable` type's derived schema; decode of a canned raw-JSON string into `T`; dynamic schema → `JSONValue` parse; error mapping. Real constrained generation in milestone 7 (gated).
- [ ] Run `swift test --filter GuidedShapesTests` — all pass.

## Workflow
- Use `/tdd` — write failing schema-derivation + decode + JSONValue tests first.