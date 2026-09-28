---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mkz0bhsfcw22jhfhc589se
  text: |-
    Research:
    - `Pooling.callAsFunction(_:mask:normalize:applyLayerNorm:)` takes an optional `MLXArray` of shape [batch, tokens]. `.mean` and `.max` multiply the hidden states by the mask (expanded on the last axis). `.last` sums `mask.asType(.int32)` on the last axis to get the token count of each row. So an int32 mask with 1 for a real token and 0 for a pad is correct for each strategy.
    - The Qwen3 embedder `attentionMask` is a [batch, tokens] key-padding mask: nonzero means attend. It does `asType(.bool)`, so the same int32 mask is correct for the model.
    - `MLXArray([Int], shape)` makes an int32 array.
    - A plain root `swift test` has no Metal library, and the first GPU evaluation of an `MLXArray` aborts the process (see `MetalLibraryBootstrapIntegrationTests`). No root unit test evaluates an `MLXArray`. So the batch builder makes plain Swift arrays (`PaddedTokenBatch`), and the unit test reads them with no MLX. Only the body of `LiveEmbeddingContainer.embed(texts:in:)` converts them to `MLXArray`.
    - The gated suite that resolves `RealModels.embedding` (`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`) is `IntegrationTests` in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. The new gated test goes in that suite, and loads only the embedder through `LiveModelLoader.loadEmbedder`.
    - The model is on this machine (`~/.cache/huggingface/hub/models--mlx-community--Qwen3-Embedding-0.6B-4bit-DWQ`).
  timestamp: 2026-09-28T18:20:48.369538+00:00
- actor: claude-code
  id: 01m3mm88zsxta5pehtgzy9cvw4
  text: |-
    Gated real-model numbers, `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` (on this machine), test `IntegrationTests.batchVectorEqualsVectorOfTextAlone` in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. Texts of 19, 126 and 523 characters, embedded as one batch and one at a time. Cosine of each pair:
    - Before the fix (the old embed body, with the fix stashed): [0.4379859, 0.2749719, 1.0000001]. The test failed with 2 issues (the two shorter rows). Note: the first "before" run printed its output through a pipe that cut the test lines, so the "before" run was done two times; the numbers are from the second run.
    - After the fix: [0.9994725, 1.0, 1.0000001]. 1 test in 1 suite passed after 1.9 seconds.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Resolution/PaddedTokenBatch.swift (new), Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift (embed body only; still in `container.perform`), Tests/FoundationModelsRouterTests/PaddedTokenBatchTests.swift (new, failed first: type not found), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift (new gated test, shared `makeLiveLoader()`).
    - next: /test
  timestamp: 2026-09-28T18:25:52.121177+00:00
- actor: claude-code
  id: 01m3mmfaqyt42973n7h13mg5xz
  text: |-
    ### test — green
    - evidence: `swift test` one time — 1387 tests in 175 suites passed (2 known issues, the existing `withKnownIssue` tests), 20 tests in 9 suites passed, 19 tests in 3 suites passed; the "PaddedTokenBatch padding mask" suite passed. Clean `swift build --build-tests --scratch-path <scratchpad>/cleanbuild`: no compiler warning (only the SwiftPM manifest cache "disk I/O error" lines and "missing creator for mutated node" from the build tool). `swift test --package-path IntegrationTests --filter IntegrationTests.batchVectorEqualsVectorOfTextAlone` built the IntegrationTests package and ran 1 test, passed.
    - next: /commit
  timestamp: 2026-09-28T18:29:43.294374+00:00
position_column: doing
position_ordinal: '80'
title: 'LiveEmbeddingContainer.embed: pool with the padding mask, so a batch vector is the vector of its own text'
---
## What
Reported by the FoundationModelsMultitool session on 2026-09-28; confirmed in the code by the router session. Multitool task ^hd8266a (01M3G1K0GGX4F743R42HD8266A, `UnknownToolHintLiveTests`) waits on this fix.

`LiveEmbeddingContainer.embed(texts:in:)` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:817-843`) embeds a batch as one padded tensor. It right-pads each row with `tokenizer.eosTokenId`, gives `mask` to the model, and then calls `context.pooling(output, normalize: true, applyLayerNorm: true)` (line 839) with NO mask. `Pooling.callAsFunction` (`.build/checkouts/mlx-swift-lm/Libraries/MLXEmbedders/Pooling.swift:151-179`) then uses a mask of all ones (line 155). For a `.last` pooling model (the Qwen3 embedders, `MLXEmbedders/Models/Qwen3.swift:320`), it takes the last PADDED position, so every row that is shorter than the longest row gets the hidden state of a pad token, and its vector depends on the pad count, not on its text. `.mean` and `.max` pooling include the pad positions too.

Measured in FoundationModelsMultitool with `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`: for a batch of 9 tool blocks (1498-2916 chars), the cosine between the batch vector and the vector of the same text embedded alone is 0.56-0.77 for the 8 shorter rows and 1.00 for the longest row. The longest row wins the cosine signal for almost every query, and a one-sentence edit of one row changes its rank because it changes its pad count. This affects each batch embed: the registry catalog embed, the multitool `searchTools`, and any `PooledEmbedder` user.

Second defect in the same function: the mask is `padded .!= eosTokenId` (line 834), so a real EOS token that the tokenizer adds at the end of a text is also masked out. Build the mask from the token count of each row instead.

- Build the mask from the token count of each row (1 for each real token, 0 for each pad), and give it to the model AND to `context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)`. Put the mask builder in a small internal function so a unit test can reach it with no model.
- Keep the embed call on the pool entry's work queue (task ^5339rgt).

## Acceptance Criteria
- [ ] `embed(texts:in:)` builds the mask from the token count of each row, and gives it to the model and to `context.pooling(..., mask:)`.
- [ ] For each text, the vector from a batch equals the vector from a batch of one, to float tolerance (cosine >= 0.999), for texts of different lengths.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] A unit test over the mask builder: rows of token counts [3, 5] padded to 5 give the mask [[1,1,1,0,0],[1,1,1,1,1]], and a row that ends with the EOS id keeps that position at 1.
- [ ] A gated real-model test (in the gated real-model suite that already loads the embedding model): embed 3 texts of clearly different lengths as one batch and one at a time; expect cosine >= 0.999 for each pair. Today it gives about 0.6 for the shorter rows. Run it one time if the model is on this machine, and record the numbers; if it is not, record that.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #defect #embedding #cross-repo