---
assignees:
- claude-code
depends_on:
- 01KWS4MN1XR5Y76BTSKQH27HA7
position_column: todo
position_ordinal: '8280'
title: 'Footprint: hybrid linear/full-attention models overcount KV-cache layers (e.g. Qwen3.5-2B-mxfp4)'
---
## What

Discovered while researching ^qh27ha7 (text_config parsing): `mlx-community/Qwen3.5-2B-mxfp4`'s `config.json` `text_config` declares a hybrid attention architecture — `layer_types` is a 24-element array alternating `"linear_attention"`/`"full_attention"` every 4th layer (`full_attention_interval: 4`, so 6 of 24 layers are `full_attention`; the other 18 are `linear_attention`, a fixed-size recurrent state that does **not** grow with context). Once ^qh27ha7 lands, this repo will parse successfully, but `RepoMetadata.footprint`'s `kvBytes(context:)` (`Sources/FoundationModelsRouter/Sizing/Footprint.swift`) multiplies by the full `num_hidden_layers` (24) as if every layer materializes a growing per-token KV cache — overestimating the KV cache by ~4x for this model, since only the 6 `full_attention` layers actually do.

Grep confirms `numHiddenLayers`/`.layers` are used only in `RepoMetadata.swift`, `Footprint.swift`, and their tests — no other call sites — so this is safely scoped to those two files.

Files:

1. `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`: add `let layerTypes: [String]?` (keyed `"layer_types"`) to the private `RepoConfig.TextConfig` struct added in ^qh27ha7. In `RepoMetadata.init(raw:)`, compute a new value: when `config.textConfig?.layerTypes` is present, count elements equal to `"full_attention"`; when absent (the common, non-hybrid case), default to the resolved `numHiddenLayers` (preserves current behavior for every existing model/fixture). Add this as a new stored property `numFullAttentionLayers: Int` on `RepoMetadata`, threaded through its memberwise `init` and `Codable` conformance alongside the existing fields.
2. In `RepoMetadata`'s `footprint` computed property, pass `numFullAttentionLayers` — not `numHiddenLayers` — as the `numHiddenLayers:` argument to `Footprint`'s config-shaped initializer, since that argument is only ever used to multiply `kvBytes`. `numHiddenLayers` itself stays as the raw architecture fact on `RepoMetadata` (unchanged meaning, still 24 for this model).

## Acceptance Criteria

- [ ] For a hybrid config with a 24-entry `layer_types` where 6 entries are `"full_attention"` (matching the real `mlx-community/Qwen3.5-2B-mxfp4` `text_config`), `RepoMetadata.numFullAttentionLayers == 6` and `footprint.kvBytes(context:)` scales with 6 layers, not 24.
- [ ] For a config with no `layer_types` field (every existing test fixture and the common non-hybrid case), `numFullAttentionLayers == numHiddenLayers` and `footprint` behaves exactly as before — no regression.
- [ ] `RepoMetadata`'s `Codable` round-trip includes `numFullAttentionLayers`.

## Tests

- [ ] `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift`: add a test (e.g. `hybridAttentionLayerCounting`) using the real `mlx-community/Qwen3.5-2B-mxfp4` `text_config.layer_types` array (24 entries, `full_attention_interval: 4`, pattern: 3× `linear_attention` then 1× `full_attention`, repeated 6 times) as a canned fixture — asserts `metadata.numFullAttentionLayers == 6` and `footprint.kvBytes(context:)` matches the hand-computed value for 6 layers (vs. the wrong value for 24).
- [ ] Update the existing `codableRoundTrip` test in the same file (or add a variant) to cover `numFullAttentionLayers`.
- [ ] Run `swift test --filter RepoMetadataTests` and `swift test --filter FootprintTests` — expect all tests, including the new ones, to pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
