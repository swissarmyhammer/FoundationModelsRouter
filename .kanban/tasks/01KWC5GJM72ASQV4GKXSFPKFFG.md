---
comments:
- actor: wballard
  id: 01kwddpy2976sw8w5kd4pshhce
  text: |-
    Implemented milestone 8a (TDD, RED confirmed before GREEN).

    New files:
    - Sources/FoundationModelsRouter/Guided/Grammar.swift — `enum Grammar { jsonSchema, ebnf }` + `source` accessor.
    - Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift — `GuidedGenerationError` (unsupportedSchemaConstructs/invalidJSONSchema/emptyGrammar), real GPU-free `Grammar.validateForXGrammar()` (recursive JSON walk rejecting $ref/allOf/format anywhere), `LoadedLLMContainer` default guided impl (validate then notWiredForLiveInference), and `RoutedLLM` extension: `respond(to:following:)` + `makeGuidedSession(_:instructions:workingDirectory:)`.

    Edited:
    - Resolution/ModelLoader.swift — added `respond(to:instructions:following:)` requirement to `LoadedLLMContainer`.
    - RoutedLLM.swift — refactored `makeSession` into a shared internal builder taking `grammar`.
    - Session/RoutedSession.swift — added `nonisolated var grammar: Grammar?` to protocol + actor; `respond` branches to the constrained container path when grammar present; chokepoint `generate(grammar:)`/`makePartialEvent(grammar:)` stamp `grammar.source` onto both bracket events. streamResponse stays unconstrained (records nil grammar).

    Decisions:
    - Real xgrammar decode (GrammarConstraint/GuidedGenerationLoop, needs GPU tokenizer+model) is the documented milestone-7 seam: live ModelContainer inherits the default guided impl → validates (real) then throws notWiredForLiveInference. Grammar validation + error mapping + recording are all real and unit-tested.
    - respond(to:following:) reuses makeGuidedSession so the one-shot funnels through the same chokepoint and records the grammar.

    Tests: Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift — 10 tests (incl. parametrized $ref/allOf/format) all green. `swift test --filter GuidedGenerationTests` green; full `swift test` green (77 unit + 1 gated integration), no warnings. Build env DEVELOPER_DIR=Xcode-beta. Left in `doing`.
  timestamp: 2026-06-30T23:26:58.633238+00:00
- actor: wballard
  id: 01kwde2m2m61nw7272jqjacpps
  text: |-
    Adversarial double-check returned REVISE with 2 findings; resolved:

    Finding 1 (Medium, real false-positive) — FIXED. The validation walked every object key uniformly, so a property literally NAMED `format`/`$ref`/`allOf` under `properties` was wrongly rejected. Made the walk position-aware (Grammar.collectUnsupportedKeywords): keys of name→subschema maps (properties/patternProperties/$defs/definitions/dependentSchemas) are names — only their values are recursed as subschemas; instance-data keywords (enum/const/default/examples) are not walked. TDD: added 3 tests (keywordAsPropertyNameAccepted, keywordInsideInstanceDataAccepted — both confirmed RED before the fix — plus realKeywordUnderSameNamedPropertyRejected as a regression guard that a genuine nested `format` keyword is still caught). All green.

    Finding 2 (Low, latent) — ACCEPTED with justification, not changed. `GuidedGenerationError` shares its name with MLXGuidedGeneration.GuidedGenerationError. The task description explicitly mandates this exact symbol name ("define a GuidedGenerationError"; acceptance criteria reference it), so renaming would deviate from the named acceptance contract. No collision today (the router module imports only MLXLMCommon/MLXLLM/MLXEmbedders; no file both imports MLXGuidedGeneration and references the bare name). When milestone 7 wires LiveModelLoader's ModelContainer.respond(...following:) to real xgrammar decode, that seam must module-qualify (FoundationModelsRouter.GuidedGenerationError vs MLXGuidedGeneration.GuidedGenerationError) when mapping the MLX error — noting here for the milestone-7 implementer.

    Verification (DEVELOPER_DIR=Xcode-beta): swift build clean (no warnings); swift test --filter GuidedGenerationTests = 13/13; full swift test = 80 unit tests + 1 gated integration, all green. Task left in `doing`.
  timestamp: 2026-06-30T23:33:21.620369+00:00
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
position_column: doing
position_ordinal: '80'
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