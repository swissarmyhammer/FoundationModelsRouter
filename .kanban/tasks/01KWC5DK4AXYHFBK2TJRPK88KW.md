---
depends_on:
- 01KWC5C3B35X6N0DYZJYZ044BE
- 01KWC5CQ49ZCF1VVP9FW6T4QZF
position_column: todo
position_ordinal: '8680'
title: HF repo metadata reader + fit (milestone 3)
---
## What
Read the two small things each candidate repo needs for sizing — without downloading weights — and feed the footprint math. Cached per `(repo, revision)`. Plan "Repo metadata (milestone 3)".

- `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`:
  - Fetch `config.json` at the repo's revision (architecture for KV math: `num_hidden_layers`, `num_attention_heads`, `num_key_value_heads` (GQA; fall back to attention heads), `head_dim` or `hidden_size/num_attention_heads`, plus the `quantization` block).
  - Fetch the repo tree listing (`…/tree/{rev}`, LFS `size`) and sum `*.safetensors` byte sizes → resident weight bytes (1:1).
  - Use `MLXHuggingFace` resolution where it exposes these; otherwise the HF HTTP API. Inject the fetch behind a protocol (`MetadataSource`) so tests use canned JSON — no network in unit tests.
  - Map a `ModelRef` → `FootprintInput` (feeds milestone-2 `Footprint`).
  - A repo missing `config.json` OR weight sizes ⇒ surface `metadataUnavailable` (a reason string), so the resolver can skip it.
- Cache parsed metadata per `(repo, revision)` under the configured `cacheDir`.

## Acceptance Criteria
- [ ] Given canned `config.json` + tree listing, produces the correct `FootprintInput` (layers/kvHeads/headDim/weightBytes), and `Footprint.footprint(context:)` over it matches a hand-computed value.
- [ ] GQA fallback: missing `num_key_value_heads` uses `num_attention_heads`; missing `head_dim` uses `hidden_size/num_attention_heads`.
- [ ] Missing `config.json` or no `*.safetensors` in the tree ⇒ `metadataUnavailable("…")`, not a crash.
- [ ] Second read for the same `(repo, revision)` hits the cache (fetch invoked once).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` (Swift Testing) with an injected `MetadataSource` returning canned fixtures: happy path, GQA/head_dim fallbacks, missing-config and no-safetensors → metadataUnavailable, cache-hit (fetch count == 1).
- [ ] Run `swift test --filter RepoMetadataTests` — all pass.

## Workflow
- Use `/tdd` — write failing fixture-driven parsing tests first.