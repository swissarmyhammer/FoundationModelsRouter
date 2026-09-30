---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3re1nj7e19s07a92rv8c1pr
  text: |-
    ### done in Extras
    - The fix is in FoundationModelsExtras 0b487c6 (Extras board task 01M3RB2GRGGDBJCGMD9H3ZRFA3): the mask comes from the row lengths, and the model and the pooling get it. Helper: EmbeddingBatchPadding, with a unit test.
    - Router pin moved to 0b487c6 (root and IntegrationTests). IntegrationTests.batchVectorEqualsVectorOfTextAlone passes: cosines [0.9994725, 1.0, 1.0000001].
  timestamp: 2026-09-30T05:54:21.895216+00:00
position_column: done
position_ordinal: ffffffb780
title: 'Extras MLXEmbedding: pool with the padding mask, so a batch vector is the vector of its own text'
---
## What
The Extras `MLXModelLoader` makes the embedding model of the family (`MLXEmbedding` in `FoundationModelsExtras/Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`, at Extras 80fc0a2). Its `embed(texts:in:)` has the bug that the Router fixed in task ^nmmnn7k:

- It pools with no mask: `context.pooling(output, normalize: true, applyLayerNorm: true)`. For a `.last` pooling model (the Qwen3 embedders), each row that is shorter than the longest row gets the hidden state of a pad token.
- Its model mask is `padded .!= padToken`. The pad token is `eosTokenId`, so this mask also removes a real end token that `addSpecialTokens: true` adds.

The Router deleted its own embedder (`LiveEmbeddingContainer`, `PaddedTokenBatch`) in ^jkfp5fp and now loads embeddings through `MLXModelLoader`. So the gated test `IntegrationTests.batchVectorEqualsVectorOfTextAlone` fails now:

```
[batchEmbedCosine] [0.4379859, 0.2749719, 1.0000001]
```

(floor 0.999; the longest text passes, the two shorter texts fail.)

## Fix (in the FoundationModelsExtras repository)
- Build the mask from the length of each token row (1 for a real token, 0 for a pad), not from the pad token value.
- Give that mask to the model (`attentionMask:`) and to the pooling (`context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)`).
- Keep the row padding and the mask as plain Swift arrays in a helper that a unit test can read with no MLX (the Router's deleted `PaddedTokenBatch` did this), because a root unit test cannot evaluate an `MLXArray`.
- Push Extras, then move the Router pin (root and `IntegrationTests/Package.resolved`) to the new revision.

## Acceptance Criteria
- [ ] `swift test --package-path IntegrationTests --filter IntegrationTests.batchVectorEqualsVectorOfTextAlone` in the Router passes (each cosine >= 0.999).
- [ ] An Extras unit test pins the mask of a right-padded batch, including a row whose last real token is the end token.

## Tests
- [ ] Extras unit test for the padded batch and its mask.
- [ ] The Router gated test above passes on the new Extras revision.
#model-pool