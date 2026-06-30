---
comments:
- actor: wballard
  id: 01kwcw3zzyqkvwg12pahsqsp6b
  text: |-
    Implemented milestone-2 footprint math TDD-style.

    Sources/FoundationModelsRouter/Sizing/Footprint.swift — pure value struct (Sendable, Equatable), no I/O, no MLX:
    - Stored resolved fields: weightBytes, layers, kvHeads, headDim.
    - Designated init takes resolved values; a config-shaped init applies the two fallbacks (GQA: numKeyValueHeads ?? numAttentionHeads; head-dim: head_dim ?? hidden_size/num_attention_heads).
    - kvBytes(context:) = 2(K+V) * layers * context * kvHeads * headDim * 2(fp16). Named constants keyValueTensors/cacheElementBytes.
    - footprint(context:) = weightBytes + kvBytes. NO x1.2 margin (left for fit step, per plan).
    - embedder(weightBytes:) factory: zero KV dims so kvBytes==0 and footprint==weightBytes via a single code path (no autoregressive cache).

    Tests/FoundationModelsRouterTests/FootprintTests.swift (Swift Testing, 7 tests): hand-computed kvBytes (2/4/8 arch, ctx 16 => 4096); footprint = weights+KV; monotonicity over an explicitly-typed [Int] context array; GQA fallback equals explicit MHA; GQA<MHA; head-dim fallback from hidden_size; embedder = weightBytes with KV term 0.

    Verified RED first (cannot find type 'Footprint'), then GREEN. swift test --filter FootprintTests => 7/7 pass. Full swift test => 20 pass + 1 gated integration skip. DEVELOPER_DIR=Xcode-beta. Left in doing for review.
  timestamp: 2026-06-30T18:19:32.222155+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: doing
position_ordinal: '80'
title: Footprint math (milestone 2)
---
## What
Pure footprint/budget functions given quant + weight bytes + architecture. No I/O, no MLX. Plan "Footprint estimate (milestone 2)".

- `Sources/FoundationModelsRouter/Sizing/Footprint.swift`:
  - Input struct capturing the architecture fields needed for KV math: `layers (num_hidden_layers)`, `kvHeads (num_key_value_heads, GQA; fall back to num_attention_heads)`, `headDim (head_dim or hidden_size/num_attention_heads)`, plus `weightBytes` (Σ `*.safetensors` sizes, ≈ resident 1:1).
  - `kvBytes(context:) = 2 * layers * context * kvHeads * headDim * 2`  // K+V, fp16 cache (2 bytes/elt) regardless of weight quant.
  - `footprint(context:) = weightBytes + kvBytes(context)`  // overhead absorbed by the ×1.2 margin at fit time, NOT here.
  - Embedder variant: `footprint ≈ weightBytes` (no autoregressive KV cache).
  - Keep the ×1.2 safety margin OUT of these functions (it belongs to the fit step); these return the raw estimate.

## Acceptance Criteria
- [ ] `kvBytes` matches the formula `2 * layers * ctx * kvHeads * headDim * 2` for hand-computed examples.
- [ ] Larger `context` strictly increases `footprint` (long-context profiles fit smaller models).
- [ ] GQA fallback: when `num_key_value_heads` absent, KV math uses `num_attention_heads`.
- [ ] Embedder footprint equals `weightBytes` (no KV term).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/FootprintTests.swift` (Swift Testing): hand-computed KV bytes for a known small arch; monotonicity in context; GQA-vs-MHA branch; embedder = weightBytes.
- [ ] Run `swift test --filter FootprintTests` — all pass.

## Workflow
- Use `/tdd` — write failing arithmetic tests with injected values first.