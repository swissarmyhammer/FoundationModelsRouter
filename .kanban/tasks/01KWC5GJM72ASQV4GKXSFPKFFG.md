---
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
position_column: todo
position_ordinal: 8b80
title: 'Guided generation: Grammar + raw guided sessions (milestone 8a)'
---
## What
Grammar-constrained decoding via xgrammar (`MLXGuidedGeneration`, PR #334): the raw layer that the typed/dynamic shapes build on. Plan "Guided generation".

- `Sources/FoundationModelsRouter/Guided/Grammar.swift`:
  - `enum Grammar { case jsonSchema(String); case ebnf(String) }`.
- `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift`:
  - `extension RoutedLLM`:
    - `func respond(to:following grammar: Grammar) async throws -> String` — unparsed, constrained text out, via `GrammarConstraint(jsonSchema:)` + `GuidedGenerationLoop.run(…)` over the resident `ModelContainer`.
    - `func makeGuidedSession(_ grammar: Grammar, instructions: String? = nil, workingDirectory: URL? = nil) -> RoutedSession` — a session whose every `respond` is constrained to `grammar` (returns raw text; forkable).
  - Guided output is **whole-chunk** (no token streaming) — `respond(...following:)` returns the complete schema-valid result; `streamResponse` stays unconstrained-only.
  - Route through the same private `generate` chokepoint so guided turns are recorded (carry `grammar` in the event).
  - **xgrammar subset caveat:** grammars using `$ref` / `allOf` / `format` are normalized or rejected with a clear error (surfaced like a metadata failure, not a crash) — define a `GuidedGenerationError`.

## Acceptance Criteria
- [ ] `respond(to:following: .jsonSchema(...))` returns text that validates against the schema (asserted in the gated integration suite); unit tests assert the grammar is compiled and unsupported constructs raise `GuidedGenerationError` (not a crash).
- [ ] A grammar with `$ref`/`allOf`/`format` that can't be normalized produces a clear typed error.
- [ ] A guided session constrains every `respond`; it is forkable (fork inherits the grammar — wired with milestone 9).
- [ ] Guided turns funnel through the `generate` chokepoint and record `grammar` (assert with an InMemoryRecorder).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift` (Swift Testing): grammar compilation for a small JSON schema + an EBNF grammar; unsupported-construct → `GuidedGenerationError`; chokepoint records grammar. Real constrained decoding asserted in milestone 7 (gated).
- [ ] Run `swift test --filter GuidedGenerationTests` — all pass.

## Workflow
- Use `/tdd` — write failing grammar-compile + error-mapping + recording tests first.