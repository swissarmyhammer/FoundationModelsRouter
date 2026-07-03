---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwksmvmbgzg4fgd2zgmas2mq
  text: |-
    Implemented per /tdd workflow.

    RED: Added the new `@Test multiModelDirectGeneration()` first, calling `ExampleHarness.makeRouter(cannedResponses: [.flash: ..., .standard: ...])` — an API that didn't exist yet. `swift test --filter ExamplesTests` failed to compile exactly as expected ("incorrect argument label in call (have 'cannedResponses:', expected 'cannedResponse:')").

    GREEN: Extended `ExampleHarness.StubModelLoader` with a `perSlotCanned: [ModelSlot: String]` field, resolved in `loadLLM` as `perSlotCanned[slot] ?? canned`, and threaded a new `cannedResponses: [ModelSlot: String] = [:]` parameter through `makeRouter` (default empty, so every pre-existing example's single-`cannedResponse` behavior is unchanged). Added the new example under `// MARK: - Multi-model direct generation` (between Generation and Embedding sections): one `resolve`, then `profile.flash.makeSession` for a cheap triage turn and `profile.standard.makeSession` for the heavyweight answer, asserting each returned its own distinct per-slot canned string and `profile.standard.chosen != profile.flash.chosen`.

    Verification:
    - `swift test --filter ExamplesTests`: 10/10 pass (9 pre-existing + 1 new).
    - `swift test` (full suite): 129/129 pass across 20 suites; gated milestone-7 integration suite correctly skipped (no network/GPU).
    - Adversarial double-check agent: PASS — confirmed the per-slot wiring is genuine (not tautological), pre-existing behavior is unchanged, embedding slot is unaffected, and style matches file conventions.

    Diff scope: only Tests/FoundationModelsRouterTests/ExamplesTests.swift (57 insertions, 3 deletions). Leaving task in `doing` for review per the implement/really-done workflow.
  timestamp: 2026-07-03T10:51:00.107425+00:00
position_column: done
position_ordinal: '9880'
title: Add multi-model direct generation example to ExamplesTests
---
## What

The living-documentation suite `Tests/FoundationModelsRouterTests/ExamplesTests.swift` shows the router's core value proposition nowhere: one `Router.resolve` produces a `LanguageModelProfile` with **two co-resident local generation models** (`profile.standard` and `profile.flash`, both `RoutedLLM`), yet every existing example drives only `profile.standard`. Add a thoughtful, copy-pasteable example that uses **both** resident models together for plain (unguided) direct generation — routing light work to `flash` and heavy work to `standard`.

Work, all in `Tests/FoundationModelsRouterTests/ExamplesTests.swift`:

- [x] Extend `ExampleHarness` so the stub loader can vend a **distinct canned response per slot**. `StubModelLoader.loadLLM(_:slot:context:reporting:)` already receives the `ModelSlot`, so: add a `cannedResponses: [ModelSlot: String]` (or equivalent `standardResponse:`/`flashResponse:` parameters) path through `makeRouter`, keeping the existing single `cannedResponse: String = "OK"` behavior as the default so all current examples compile and pass unchanged.
- [x] Add a new example under a `// MARK: - Multi-model direct generation` section, e.g. `@Test("Route work across two resident models: flash triages, standard answers")`. Body, in the established narrative style (comment-dense, every line after `ExampleHarness.makeRouter` being real production usage):
  - Author one `ProfileDefinition` with `standard`, `flash`, and `embedding` candidates (reuse the `mlx-community/Qwen2.5-*` refs used by the other examples) and resolve it once via `router.resolve(_:reporting:)`.
  - Use `profile.flash.makeSession(instructions:)` for a quick, cheap turn (e.g. triage/classify the user's question), then `profile.standard.makeSession(instructions:)` for the heavyweight answer — two different local models, both already resident from the single resolve, no reload between calls.
  - Assert each slot returned its own per-slot canned output (proving the two calls really hit different models), and assert `profile.standard.chosen != profile.flash.chosen`.

Style constraints: match the suite's existing doc-comment narration; the example must run **offline** in the normal unit-test target (no network, GPU, or download), like every other example in the file.

## Acceptance Criteria

- [x] `ExamplesTests` contains a multi-model direct-generation example that drives both `profile.standard` and `profile.flash` sessions from a single resolved profile.
- [x] The example's assertions distinguish the two models: the flash turn and the standard turn return different per-slot canned strings, and `profile.standard.chosen != profile.flash.chosen`.
- [x] `ExampleHarness.makeRouter` still defaults to the current single-canned-response behavior; all pre-existing examples pass without modification to their bodies.
- [x] The new example runs offline in the unit-test target (no gated integration trait required).

## Tests

- [x] The example **is** the automated test: the new `@Test` in `Tests/FoundationModelsRouterTests/ExamplesTests.swift` passes.
- [x] Run `swift test --filter ExamplesTests` — all examples (existing + new) pass.
- [x] Run `swift test` — full unit suite stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.