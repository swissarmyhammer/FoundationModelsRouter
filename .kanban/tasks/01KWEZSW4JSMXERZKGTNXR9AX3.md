---
comments:
- actor: wballard
  id: 01kwf557a2vkcwga036z6vd69n
  text: |-
    Renamed our public enum GuidedGenerationError -> GuidedRequestError (all four cases unchanged: unsupportedSchemaConstructs/invalidJsonSchema/emptyGrammar/decodingFailed). Updated every reference (throw sites, catch sites, type annotations, doc comments, test-name strings) in: Sources/Guided/GuidedGeneration.swift, Sources/Guided/Grammar.swift, Sources/Resolution/ModelLoader.swift, Tests/GuidedGenerationTests.swift, Tests/GuidedShapesTests.swift. Grep for GuidedGenerationError across Sources+Tests is now clean.

    Note on the "module-qualify at the live seam for milestone 7" note: searched exhaustively (qualif/shadow/collision/MLXGuidedGeneration/live seam/both modules) — no such collision note exists in the tree. LiveModelLoader.swift imports MLXGuidedGeneration but never referenced our error type by name (its guided decode calls grammar.validateForXGrammar(), which throws the error without naming the type), so there was nothing to update there. Grammar & GuidedShapes left as-is.

    Impl note: MCP files edit replace_all only performed 1 replacement per file (env no-op issue); completed the rename via sed and re-grepped to confirm.

    Verified GREEN with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer: swift build clean; swift test = 110 tests / 18 suites passed (gated milestone-7 integration test skipped). Both guided suites pass.
  timestamp: 2026-07-01T15:35:58.530235+00:00
depends_on:
- 01KWC5GJM72ASQV4GKXSFPKFFG
- 01KWC5HV9BBARA3HJA26MMV0YC
position_column: done
position_ordinal: '9480'
title: Rename our GuidedGenerationError to avoid MLX name collision
---
## What
Per user code-review decision (2026-07-01): our `GuidedGenerationError` (in `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift`) shadows the imported `MLXGuidedGeneration.GuidedGenerationError` (a distinct public type with cases `incompleteOutput` / `prematureEOS`). Both are public; a caller importing both modules must module-qualify. Rename OURS to a clear, non-colliding name.

Our type is genuinely NOT a duplicate — it covers CPU-side request validation + output decoding, a different domain than MLX's runtime-generation errors — so keep its four cases; only rename the type. Also avoid `GrammarError` (already taken by `MLXGuidedGeneration.GrammarError`).

- Rename `enum GuidedGenerationError` → **`GuidedRequestError`** (preferred; covers request-time schema validation + result decode). If a clearly better name emerges, the implementer may choose it, but it must not collide with any `MLXGuidedGeneration` public type (`GuidedGenerationError`, `GrammarError`).
- Keep all four cases unchanged: `unsupportedSchemaConstructs([String])`, `invalidJsonSchema(String)`, `emptyGrammar`, `decodingFailed(String)`.
- Update every reference across `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift` (and anywhere else it's thrown/caught) and the tests `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift` + `GuidedShapesTests.swift`.
- Remove the now-obsolete "module-qualify at the live seam" milestone-7 note the guided-8a author left, since the collision is gone. Update doc comments referring to the old name.
- Keep `Grammar` and `GuidedShapes` as-is — they are additive over MLX (confirmed in review) and stay.

## Acceptance Criteria
- [ ] No public type named `GuidedGenerationError` remains in the `FoundationModelsRouter` module; it is renamed (preferably `GuidedRequestError`) with all four cases intact and all call sites/catch sites updated.
- [ ] The new name does not collide with any `MLXGuidedGeneration` public type.
- [ ] Behavior is identical (same errors thrown in the same situations); this is a rename only.
- [ ] The stale "module-qualify for milestone 7" note about the collision is removed/updated.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift` and `GuidedShapesTests.swift` reference the new name and assert the same error cases as before.
- [ ] Run `swift test` (env `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — full suite green.

## Workflow
- Use `/tdd` — this is a behavior-preserving rename; update the tests to the new symbol and keep the suite green (RED only if a reference is missed).