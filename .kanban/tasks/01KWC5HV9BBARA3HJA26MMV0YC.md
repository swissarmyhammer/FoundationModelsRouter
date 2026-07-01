---
comments:
- actor: wballard
  id: 01kwev96mcat4g0s53x5wvctcq
  text: 'Picked up 8b. Research done. Confirmed against Xcode-beta FoundationModels SDK interface: Generable exposes `static var generationSchema: GenerationSchema`; `GenerationSchema: Codable` (so JSONEncoder().encode → JSON Schema string, same trick MLXFoundationModels'' internal SchemaConverter uses); `GeneratedContent(json:) throws`; `ConvertibleFromGeneratedContent.init(_ content:) throws`. So schema-derivation + decode are pure/GPU-free and unit-testable — only real constrained generation stays gated (m7). Plan: add `.decodingFailed(String)` to GuidedGenerationError (8a type); dynamic `respond(to:matching:)` (ungated) parses raw→JSONValue; typed `respond(to:generating:)` gated `#if canImport(FoundationModels)` derives schema from T, routes through raw `respond(to:following:.jsonSchema)`, decodes via GeneratedContent+T.init. Pure helpers in enum GuidedShapes for direct unit assertions.'
  timestamp: 2026-07-01T12:43:23.148591+00:00
- actor: wballard
  id: 01kwevg13wz9rvkhehayd22p16
  text: 'Implemented 8b (TDD). GuidedGeneration.swift: added GuidedGenerationError.decodingFailed(String); ungated enum GuidedShapes.parse(_:)->JSONValue; ungated respond(to:matching jsonSchema:)->JSONValue; #if canImport(FoundationModels) block with GuidedShapes.derivedSchema<T:Generable>(for:) (encodes T.generationSchema, which is Codable, to JSON Schema) + GuidedShapes.decode<T:Generable>(_:as:) (GeneratedContent(json:)+T.init, mapping failures to .decodingFailed) + respond<T:Generable>(to:generating:). Both shapes route through raw respond(to:following:.jsonSchema); over-spec schemas already surface GuidedGenerationError via validateForXGrammar in the raw layer. New test suite GuidedShapesTests.swift (Swift Testing, stub container, no GPU): derived-schema shape, canned raw JSON->T decode, dynamic JSON->JSONValue parse, decode/parse malformed->GuidedGenerationError, over-spec dynamic schema->GuidedGenerationError, plus e2e typed+dynamic through the chokepoint. Note: GenerationSchema JSON encoding has nondeterministic key order, so the e2e stamped-grammar assertion compares parsed JSONValue (order-independent) not raw bytes. GREEN: swift test --filter GuidedShapesTests = 8/8; full swift test = 96/96 + gated integration suite. Reviewer flag: the Generable/FoundationModels-facing halves (derivedSchema/decode) are pure and unit-tested; only the actual constrained decode between them stays gated to milestone 7 via the raw layer''s notWiredForLiveInference seam.'
  timestamp: 2026-07-01T12:47:06.876130+00:00
- actor: wballard
  id: 01kwevm5w20m0b4dqp10k7fbjj
  text: 'really-done: verification green (swift test --filter GuidedShapesTests 8/8; full swift test 96/96 + gated integration). Advisory double-check verdict = PASS. It independently re-ran the filtered suite (8/8), confirmed all 5 requirements met (typed shape derives+routes+decodes; dynamic shape parses to JSONValue never fixed type; decode failures + xgrammar-subset rejections both surface as GuidedGenerationError; no GPU/network; acronym casing OK — jsonSchema label is lower-cased leading acronym matching existing Grammar.jsonSchema), verified tests are not tautological (over-spec test really hits validateForXGrammar; .number(1)==1.0 sound since JSONValue tries Bool before Double), and found no dead code / gating mistakes / signature breakage. Leaving task in doing for /review.'
  timestamp: 2026-07-01T12:49:22.818089+00:00
depends_on:
- 01KWC5GJM72ASQV4GKXSFPKFFG
- 01KWC5C3B35X6N0DYZJYZ044BE
position_column: doing
position_ordinal: '80'
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