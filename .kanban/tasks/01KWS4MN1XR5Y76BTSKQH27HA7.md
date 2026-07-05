---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwsa77psgfhm98905gr3yyg0
  text: |-
    Implemented via TDD.

    Changes in Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:
    - Added `RepoConfig.TextConfig: Decodable` nested struct decoding the same five sizing fields via the same snake_case CodingKeys.
    - Added `let textConfig: TextConfig?` to `RepoConfig`, keyed "text_config".
    - Added `RepoConfig.sizingSource` computed property (returns a private `SizingFields` tuple typealias) that selects a whole coherent source: top level if it has both `num_hidden_layers`/`num_attention_heads`, else `textConfig` if it has both, else nil. Never mixes fields across levels.
    - `RepoMetadata.init(raw:)` now uses `config.sizingSource` instead of reading fields directly from the top level, preserving the existing `metadataUnavailable` error messages.

    Tests added to Tests/FoundationModelsRouterTests/RepoMetadataTests.swift:
    - `qwenVLTextConfigFallback`: uses the actual verbatim config.json fetched live from https://huggingface.co/mlx-community/Qwen3.5-2B-mxfp4/resolve/main/config.json (curl'd during implementation) as the canned fixture. Asserts numHiddenLayers==24, numAttentionHeads==8, numKeyValueHeads==2, headDim==256, hiddenSize==2048.
    - `topLevelSizingFieldsWinOverTextConfig`: synthetic config with complete-but-different values at both levels; asserts every field resolves from the top level (proves no per-field mixing, e.g. numKeyValueHeads 8 not 2).

    TDD: watched both new tests fail RED first (qwenVLTextConfigFallback failed with the expected metadataUnavailable; topLevelSizingFieldsWinOverTextConfig already passed against old code since it only exercises unaffected top-level behavior — expected, not a miss), then implemented to GREEN.

    Verification: `swift build` clean, `swift build --build-tests` clean, `swift test --filter RepoMetadataTests` 14/14 pass, full `swift test` 160/160 pass across 21 suites (1 integration suite appropriately skipped as gated). Adversarial double-check dispatched for sign-off.
  timestamp: 2026-07-05T14:16:51.673807+00:00
- actor: claude-code
  id: 01kwsaefnw5n68n8vx2ggsw49h
  text: |-
    Adversarial double-check verdict: PASS. One non-blocking suggestion — add coverage for the partial-top-level fall-through path (top level has only one of the two required fields, `textConfig` has both) — addressed by adding `partialTopLevelFallsThroughToTextConfig`.

    Final verification (fresh run): `swift build` clean, `swift build --build-tests` clean, `swift test --filter RepoMetadataTests` 15/15 pass, full `swift test` 161/161 pass across 21 suites (1 integration suite appropriately skipped as gated). Zero regressions.

    All acceptance criteria met:
    - Qwen3.5-2B-mxfp4 VLM shape (sizing fields only under text_config, sibling vision_config with distinct field names) parses successfully.
    - A config with both required fields at the top level is read entirely from the top level, ignoring text_config even when present (no per-field mixing) — covered by both the fully-complete-top-level case and the partial-top-level-falls-through case.
    - A config with neither level having both required fields still throws metadataUnavailable (existing `missingArchitectureFieldsUnavailable` test, unchanged).
    - All existing RepoMetadataTests pass unchanged.

    Leaving in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-05T14:20:49.212069+00:00
- actor: claude-code
  id: 01kwsb9wjekqt8ddfve2q5kjm6
  text: |-
    Addressed the review finding: extracted a shared `private struct SizingFields: Decodable` (nested directly under `RepoMetadata`, sibling to `RepoConfig`) holding the five architecture fields (numHiddenLayers, numAttentionHeads, numKeyValueHeads, headDim, hiddenSize), their snake_case CodingKeys, a `hasRequiredFields` helper, and a `resolved: ResolvedSizing` tuple accessor.

    The previously-existing private tuple typealias (also named `SizingFields`) was renamed to `ResolvedSizing` to free the name and avoid shadowing the new decodable struct within `RepoConfig`'s nested scope — same five-element optional-Int tuple shape, no behavior change.

    `RepoConfig` and `RepoConfig.TextConfig` no longer declare the five fields/CodingKeys themselves. Both now hold `let fields: SizingFields` and implement a custom `init(from decoder:)` that decodes `SizingFields(from: decoder)` directly against their own decoder scope (RepoConfig's top level, or TextConfig's `text_config` sub-object) — Codable supports requesting multiple containers/nested decodes off the same decoder without consuming it, so this is a pure mechanical restructuring, not a decoding change. `RepoConfig`'s own `CodingKeys` now holds only `textConfig`. The `sizingSource` resolution logic (top-level-complete wins, else text_config-complete, else nil, never per-field mixed) is unchanged — same two `if` checks, now reading `fields.hasRequiredFields` / `.resolved`.

    Verification: `swift build` clean, `swift build --build-tests` clean, `swift test --filter RepoMetadataTests` 15/15 pass, full `swift test` 161/161 pass across 21 suites (1 integration suite skipped as gated) — zero regressions. Tests/FoundationModelsRouterTests/RepoMetadataTests.swift was not touched (pure internal refactor). Adversarial double-check verdict: PASS, no findings.

    Checked off the review finding checklist item. Leaving in `doing` for `/review`.
  timestamp: 2026-07-05T14:35:47.150108+00:00
- actor: claude-code
  id: 01kwsc68h04nmezbv90c0hn3zq
  text: |-
    Addressed the 2026-07-05 09:37 review finding (force unwraps on sizing.numHiddenLayers!/numAttentionHeads!).

    Redesigned so the guarantee is type-safe rather than a guard/preconditionFailure band-aid:
    - `ResolvedSizing` changed from a five-optional-Int tuple typealias to a plain struct with `numHiddenLayers: Int` and `numAttentionHeads: Int` as non-optional, and `numKeyValueHeads`/`headDim`/`hiddenSize` remaining `Int?` (unchanged from before — they're genuinely optional/derivable per RepoMetadata's own fields).
    - `SizingFields.resolved` (previously an unconditional tuple accessor, paired with a separate `hasRequiredFields` bool) now returns `ResolvedSizing?`, using `guard let numHiddenLayers, let numAttentionHeads else { return nil }` to construct the struct. This is the only construction path for `ResolvedSizing`, so holding one is a compile-time proof the two required fields are present — `hasRequiredFields` is gone entirely, folded into `resolved`.
    - `RepoConfig.sizingSource` simplified from two `if hasRequiredFields { return resolved }` blocks to `fields.resolved ?? textConfig?.fields.resolved` — same three-tier resolution (top-level-complete wins, else text_config-complete, else nil), no per-field mixing, unchanged.
    - `RepoMetadata.init(raw:)` now passes `sizing.numHiddenLayers`/`sizing.numAttentionHeads` directly with no `!` — the force unwraps are gone by construction, not replaced with a differently-spelled crash.
    - Same `headDim`/`hiddenSize` presence check and same error messages, unchanged.

    Verification: `swift build` clean, `swift build --build-tests` clean, `swift test --filter RepoMetadataTests` 15/15 pass, full `swift test` 161/161 pass across 21 suites (1 integration suite skipped as gated) — zero regressions. Dispatched adversarial double-check for sign-off before handoff.

    Checked off the two force-unwrap finding checklist items. Leaving in `doing` for `/review`.
  timestamp: 2026-07-05T14:51:16.896201+00:00
- actor: claude-code
  id: 01kwsc9bramjtg973fn4edp40m
  text: |-
    Adversarial double-check verdict: PASS. Confirmed force unwraps genuinely gone with no new ones introduced, three-tier resolution behavior preserved exactly (no per-field mixing), headDim/hiddenSize check and all metadataUnavailable error message strings untouched, no other code references to the removed hasRequiredFields or old tuple ResolvedSizing shape, and build/build-tests/RepoMetadataTests(15/15)/full suite(161/161 across 21 suites, 1 gated integration test appropriately skipped) all green. Confirmed this is a genuine compiler-enforced type-safe fix, not a differently-spelled runtime crash.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-05T14:52:58.507001+00:00
position_column: done
position_ordinal: a280
title: 'RepoMetadata: fall back to text_config for VLM configs (e.g. Qwen3.5-2B-mxfp4)'
---
## What\n\nVision-language model repos (e.g. `mlx-community/Qwen3.5-2B-mxfp4`, and the broader Qwen-VL family) publish a `config.json` where the transformer sizing fields — `num_hidden_layers`, `num_attention_heads`, `num_key_value_heads`, `head_dim`, `hidden_size` — are nested under a `text_config` object instead of appearing at the top level (top level instead holds `vision_config` and VLM-specific keys). `RepoMetadata.init(raw:)` in `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift` only reads these fields from the top level of `RepoConfig`, so every VLM repo fails profile resolution with `metadataUnavailable(\"config.json is missing num_hidden_layers or num_attention_heads\")` before inference ever starts — a 100% failure, not intermittent flakiness.\n\nConfirmed against the real repo: `https://huggingface.co/mlx-community/Qwen3.5-2B-mxfp4/resolve/main/config.json` has no `num_hidden_layers`/`num_attention_heads` at its top level. They live at `text_config.num_hidden_layers: 24`, `text_config.num_attention_heads: 8`, `text_config.num_key_value_heads: 2`, `text_config.head_dim: 256`, `text_config.hidden_size: 2048`. Its sibling `vision_config` uses distinct field names (`depth`, `num_heads`) rather than colliding with the same keys.\n\nThis same repo's `text_config` also declares a hybrid linear/full-attention architecture (`layer_types`, `full_attention_interval`) that affects KV-cache sizing correctness — that is tracked separately as ^2x1rv1q (blocked on this task) and is not part of this fix.\n\n**Resolution rule — pick one coherent source, never mix fields across levels.** This mirrors HF transformers' own `get_text_config()` semantics: a composite config's language-model fields are read as a unit from one object. Per-field `??` merging across top level and `text_config` could stitch together fields from different stacks (e.g. a top-level projector-related `hidden_size` with `text_config`'s head counts) and silently size the KV cache wrong.\n\nFix `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`:\n\n1. Add a nested `TextConfig: Decodable` struct to the private `RepoConfig` struct (around line 193), decoding the same five optional fields (`num_hidden_layers`, `num_attention_heads`, `num_key_value_heads`, `head_dim`, `hidden_size`) via the same snake_case `CodingKeys` mapping.\n2. Add a `let textConfig: TextConfig?` field to `RepoConfig`, keyed `\"text_config\"` in its `CodingKeys`.\n3. In `RepoMetadata.init(raw:)` (around lines 129-150), select the sizing source as a whole: if the top-level config has both `num_hidden_layers` and `num_attention_heads`, read **all five** fields from the top level (current behavior, unchanged); otherwise, if `textConfig` has both required fields, read **all five** fields from `textConfig`; otherwise throw the existing `metadataUnavailable(\"config.json is missing num_hidden_layers or num_attention_heads\")`. The existing `head_dim`/`hidden_size` presence check then applies to whichever source was selected.\n\n## Acceptance Criteria\n\n- [x] The real `mlx-community/Qwen3.5-2B-mxfp4` `config.json` shape (sizing fields absent at top level, present only under `text_config`, alongside a sibling `vision_config`) parses successfully into a `RepoMetadata` instead of throwing `RepoMetadataError.metadataUnavailable`.\n- [x] A `config.json` whose top level has the two required fields is read entirely from the top level — `text_config` values are ignored even when present (no per-field mixing in either direction).\n- [x] A `config.json` where neither the top level nor `text_config` has both required fields still throws `metadataUnavailable`.\n- [x] All existing `RepoMetadataTests` cases still pass unchanged (top-level-only configs are unaffected).\n\n## Tests\n\n- [x] Add `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` test `qwenVLTextConfigFallback` (or similar `@Test` name) using the **actual fetched** `mlx-community/Qwen3.5-2B-mxfp4` `config.json` as the canned fixture (verbatim `text_config` and `vision_config` blocks, as captured above) — asserts `RepoMetadataReader.metadata(for:)` succeeds and returns `numHiddenLayers == 24`, `numAttentionHeads == 8`, `numKeyValueHeads == 2`, `headDim == 256`, `hiddenSize == 2048`, following the pattern of `happyPathMetadata`.\n- [x] Add a test asserting the coherent-source rule: a synthetic fixture with complete-but-different values at both top level and under `text_config` resolves every field from the top level (e.g. differing `num_key_value_heads` proves no per-field mixing).\n- [x] Run `swift test --filter RepoMetadataTests` — expect all tests, including the two new ones, to pass.\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-05 09:22)\n\n- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:310` — TextConfig duplicates the five architecture properties (numHiddenLayers, numAttentionHeads, numKeyValueHeads, headDim, hiddenSize) and their CodingKeys mappings from RepoConfig. Duplicate property definitions inflate maintenance burden — a future change to any of these fields must be applied to both locations or they will drift out of sync. Extract a protocol or shared struct defining these five common fields and their CodingKeys once, then have both RepoConfig and TextConfig conform to it, eliminating the duplication.\n\n## Review Findings (2026-07-05 09:37)\n\n- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:118` — Force unwrap on `sizing.numHiddenLayers!` — force unwraps violate the no-force-unwrap rule; even though the value is guaranteed non-nil by control flow, the compiler cannot verify this from the tuple type. Use `guard let numHiddenLayers = sizing.numHiddenLayers else { preconditionFailure(\"numHiddenLayers guaranteed by sizingSource\") }` to make the guarantee explicit, or refactor `ResolvedSizing` from a tuple to a struct with guaranteed non-nil fields.\n- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:119` — Force unwrap on `sizing.numAttentionHeads!` — force unwraps violate the no-force-unwrap rule; even though the value is guaranteed non-nil by control flow, the compiler cannot verify this from the tuple type. Use `guard let numAttentionHeads = sizing.numAttentionHeads else { preconditionFailure(\"numAttentionHeads guaranteed by sizingSource\") }` to make the guarantee explicit, or refactor `ResolvedSizing` from a tuple to a struct with guaranteed non-nil fields.\n