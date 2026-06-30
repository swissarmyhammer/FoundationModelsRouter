---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: todo
position_ordinal: '8480'
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