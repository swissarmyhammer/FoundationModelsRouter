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
position_column: doing
position_ordinal: '80'
title: 'RepoMetadata: fall back to text_config for VLM configs (e.g. Qwen3.5-2B-mxfp4)'
---
## What

Vision-language model repos (e.g. `mlx-community/Qwen3.5-2B-mxfp4`, and the broader Qwen-VL family) publish a `config.json` where the transformer sizing fields — `num_hidden_layers`, `num_attention_heads`, `num_key_value_heads`, `head_dim`, `hidden_size` — are nested under a `text_config` object instead of appearing at the top level (top level instead holds `vision_config` and VLM-specific keys). `RepoMetadata.init(raw:)` in `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift` only reads these fields from the top level of `RepoConfig`, so every VLM repo fails profile resolution with `metadataUnavailable("config.json is missing num_hidden_layers or num_attention_heads")` before inference ever starts — a 100% failure, not intermittent flakiness.

Confirmed against the real repo: `https://huggingface.co/mlx-community/Qwen3.5-2B-mxfp4/resolve/main/config.json` has no `num_hidden_layers`/`num_attention_heads` at its top level. They live at `text_config.num_hidden_layers: 24`, `text_config.num_attention_heads: 8`, `text_config.num_key_value_heads: 2`, `text_config.head_dim: 256`, `text_config.hidden_size: 2048`. Its sibling `vision_config` uses distinct field names (`depth`, `num_heads`) rather than colliding with the same keys.

This same repo's `text_config` also declares a hybrid linear/full-attention architecture (`layer_types`, `full_attention_interval`) that affects KV-cache sizing correctness — that is tracked separately as ^2x1rv1q (blocked on this task) and is not part of this fix.

**Resolution rule — pick one coherent source, never mix fields across levels.** This mirrors HF transformers' own `get_text_config()` semantics: a composite config's language-model fields are read as a unit from one object. Per-field `??` merging across top level and `text_config` could stitch together fields from different stacks (e.g. a top-level projector-related `hidden_size` with `text_config`'s head counts) and silently size the KV cache wrong.

Fix `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`:

1. Add a nested `TextConfig: Decodable` struct to the private `RepoConfig` struct (around line 193), decoding the same five optional fields (`num_hidden_layers`, `num_attention_heads`, `num_key_value_heads`, `head_dim`, `hidden_size`) via the same snake_case `CodingKeys` mapping.
2. Add a `let textConfig: TextConfig?` field to `RepoConfig`, keyed `"text_config"` in its `CodingKeys`.
3. In `RepoMetadata.init(raw:)` (around lines 129-150), select the sizing source as a whole: if the top-level config has both `num_hidden_layers` and `num_attention_heads`, read **all five** fields from the top level (current behavior, unchanged); otherwise, if `textConfig` has both required fields, read **all five** fields from `textConfig`; otherwise throw the existing `metadataUnavailable("config.json is missing num_hidden_layers or num_attention_heads")`. The existing `head_dim`/`hidden_size` presence check then applies to whichever source was selected.

## Acceptance Criteria

- [ ] The real `mlx-community/Qwen3.5-2B-mxfp4` `config.json` shape (sizing fields absent at top level, present only under `text_config`, alongside a sibling `vision_config`) parses successfully into a `RepoMetadata` instead of throwing `RepoMetadataError.metadataUnavailable`.
- [ ] A `config.json` whose top level has the two required fields is read entirely from the top level — `text_config` values are ignored even when present (no per-field mixing in either direction).
- [ ] A `config.json` where neither the top level nor `text_config` has both required fields still throws `metadataUnavailable`.
- [ ] All existing `RepoMetadataTests` cases still pass unchanged (top-level-only configs are unaffected).

## Tests

- [ ] Add `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` test `qwenVLTextConfigFallback` (or similar `@Test` name) using the **actual fetched** `mlx-community/Qwen3.5-2B-mxfp4` `config.json` as the canned fixture (verbatim `text_config` and `vision_config` blocks, as captured above) — asserts `RepoMetadataReader.metadata(for:)` succeeds and returns `numHiddenLayers == 24`, `numAttentionHeads == 8`, `numKeyValueHeads == 2`, `headDim == 256`, `hiddenSize == 2048`, following the pattern of `happyPathMetadata`.
- [ ] Add a test asserting the coherent-source rule: a synthetic fixture with complete-but-different values at both top level and under `text_config` resolves every field from the top level (e.g. differing `num_key_value_heads` proves no per-field mixing).
- [ ] Run `swift test --filter RepoMetadataTests` — expect all tests, including the two new ones, to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
