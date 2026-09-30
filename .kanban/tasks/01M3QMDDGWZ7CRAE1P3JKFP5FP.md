---
comments:
- actor: claude-code
  id: 01m3r980b9jk5848ps3m1c0a13
  text: |-
    Research:
    - Extras at 80fc0a2: `PooledEmbedder` has no `dimension`. The build of the Router fails now at `PooledEmbeddingContainer.dimension` (`embedder.dimension`). `SlotPoolLoaderTests` also reads `embedder.dimension`.
    - `MLXModelLoader.load(key:progressHandler:)` reports `ModelLoadProgress.downloading(fraction:)`, not bytes. The router `DownloadProgress` is bytes. The embedding load must map the fraction to a fixed scale.
    - The Extras `MLXEmbedding` pools with no mask (`context.pooling(output, normalize:applyLayerNorm:)`), and masks the model input with `padded .!= padToken`. The deleted `LiveEmbeddingContainer` gave the `PaddedTokenBatch` mask to the model and to the pooling (task ^nmmnn7k). The gated integration test `batchVectorEqualsVectorOfTextAlone` can show a regression.
    - `Package.resolved` is not tracked (gitignored). `IntegrationTests/Package.resolved` pins Extras at 6c399a4, which has no `MLXModelLoader`.
    - Design: `LiveModelLoader` gets an injected `embeddingLoader: any PooledModelLoader` (default `MLXModelLoader()`). `loadEmbedding` builds the pool key and calls `embeddingLoader.load(key:progressHandler:)`, then wraps the `PooledEmbedding` in a small `LoadedEmbeddingContainer` adapter. Unit tests inject a recording loader, so no network.
  timestamp: 2026-09-30T04:30:26.665345+00:00
- actor: claude-code
  id: 01m3rb0b2pev240qfbd46ng3k7
  text: |-
    Implementation landed (not committed, not pushed, as the dispatcher said):
    - `LiveModelLoader`: the embedding path delegates to an injected `embeddingLoader: any PooledModelLoader`. The public init gives `MLXModelLoader()`, and an internal init takes a test loader. `loadEmbedding` calls `embeddingLoader.load(key:progressHandler:)` in `CancellableWait.value`, maps `.downloading(fraction:)` to `DownloadProgress` as a part of `embeddingProgressScale` (1_000_000), and wraps the container in the new adapter `LoadedPooledEmbedding` (a `LoadedEmbeddingContainer` over `any PooledEmbedding`). `evict(_:)` gives an embedding container back to the embedding loader. `LiveEmbeddingContainer` is deleted, and the imports `MLX` and `MLXEmbedders` are gone from the file.
    - `PaddedTokenBatch.swift` and `PaddedTokenBatchTests.swift` are deleted: nothing else used them.
    - `PooledEmbeddingContainer`: `dimension` is read one time from `hold.container as? any PooledEmbedding`, because the Extras `PooledEmbedder` at 80fc0a2 has no `dimension`. This also repaired the build, which failed at HEAD on `embedder.dimension`.
    - Tests: `ExtrasPoolResolveTests.pooledEmbedderOfResolvedNameSharesTheResidentModel` (a resolve, then `PooledEmbedder(ref:pool:).embed(texts:)` on a `ModelPool(loader:)`, loads nothing more, and `profile.embedding.dimension` is correct). `SlotPoolLoaderTests`: three new live-loader tests with a recording embedding loader (load through the Extras protocol, load through `loadEmbedder`, evict), and the two `PooledEmbedder.dimension` reads now use `PooledEmbeddingContainer`.
    - RED was the compile failure of the new API (`embeddingProgressScale`, `embeddingLoader:`) and of `PooledEmbedder.dimension`. The new `ExtrasPoolResolveTests` test had no separate RED run, because the target did not build at HEAD.
    - `swift test`: 1420 tests in 179 suites passed (2 known issues, the existing `withKnownIssue` tests), 22 tests in 10 suites passed, 19 tests in 3 suites passed.
    - `IntegrationTests/Package.resolved` (gitignored) pinned Extras at 6c399a4, which has no `MLXModelLoader`. I set that one pin to 80fc0a2, the root pin. A backup is in the session scratchpad. I did not run `swift package update`.
  timestamp: 2026-09-30T05:01:12.662045+00:00
- actor: claude-code
  id: 01m3rb0j83zvkatenx0tykkhxw
  text: |-
    Blocker: `swift test --package-path IntegrationTests` gives 46 of 47 tests passed, 1 failed. The failed test is `IntegrationTests.batchVectorEqualsVectorOfTextAlone`: `[batchEmbedCosine] [0.4379859, 0.2749719, 1.0000001]` against the floor 0.999. The cause is in Extras, not in the Router: `MLXEmbedding.embed(texts:in:)` in `MLXModelLoader.swift` pools with no mask, and its model mask `padded .!= padToken` also removes a real end token. This is the bug that task ^nmmnn7k fixed in the deleted `LiveEmbeddingContainer`. The card forbids Router code that makes an MLX embedder, so the Router cannot fix it. The fix must land in FoundationModelsExtras. I added task 01M3RAZRZV5JVTFD960AP5256J for it, and this card now depends on it.
    Other open items that the dispatcher put out of scope for this pass: `swift package update` and the push to `origin main`, and "CI is green on the pushed commit".
  timestamp: 2026-09-30T05:01:20.003611+00:00
- actor: claude-code
  id: 01m3rb0pzjb25wwzvx110v8a8q
  text: |-
    ### implement — stuck
    - evidence: 7 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Resolution/PooledEmbeddingContainer.swift, Sources/FoundationModelsRouter/Resolution/PaddedTokenBatch.swift (deleted), Tests/FoundationModelsRouterTests/PaddedTokenBatchTests.swift (deleted), Tests/FoundationModelsRouterTests/ExtrasPoolResolveTests.swift, Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift (doc only). `swift test`: 1420 + 22 + 19 passed. `swift test --package-path IntegrationTests`: 47 tests, 1 failed (`batchVectorEqualsVectorOfTextAlone`, cosines 0.438 and 0.275 < 0.999).
    - next: fix the mask in Extras `MLXEmbedding` (task 01M3RAZRZV5JVTFD960AP5256J), move the Extras pin, run the gated test again. Then `swift package update`, push, CI.
  timestamp: 2026-09-30T05:01:24.850497+00:00
- actor: claude-code
  id: 01m3rb24r36z94sgn9xs8rd3hr
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 7 files changed, not committed; swift test 1420+22+19 passed; IntegrationTests 46/47 passed
    - blocker: IntegrationTests.batchVectorEqualsVectorOfTextAlone fails (cosines 0.438, 0.275 < 0.999). Cause is in Extras MLXEmbedding.embed(texts:in:): pooling has no mask. Fix is in ^ap5256j (Extras repository). Sent to the Extras coordinating session.
    - next: after the Extras fix is pushed, move the pin, run the gated test again, then test, commit, review.
  timestamp: 2026-09-30T05:02:11.715185+00:00
depends_on:
- 01M3RAZRZV5JVTFD960AP5256J
position_column: doing
position_ordinal: '80'
title: Embedding models load through the Extras MLXModelLoader; delete LiveEmbeddingContainer
---
**Wait for:** FoundationModelsExtras tasks 01M3QMD6V09WGE7MJDV483VHBG ("Built-in MLX loader in the core…") and 01M3QMD8KBM42ZRNF447E06VVC ("PooledEmbedder from a Hugging Face name") on the Extras board: done and pushed.

## What
There is one MLX loader in the family: `MLXModelLoader` in Extras. The Router keeps its own sizing and admission.

- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: the `.embedding` path (`loadEmbedding`, ~line 1045) delegates to `MLXModelLoader().load(key)`. Delete `LiveEmbeddingContainer` (~line 795).
- Delete `Sources/FoundationModelsRouter/Resolution/PaddedTokenBatch.swift` if nothing else uses it.
- `Resolution/PooledEmbeddingContainer.swift`: keep `PooledEmbedder(hold:)` (the Router acquires with its own `footprintBytes`/`sessionBytes`/admission). `dimension` comes from the container of the hold (`(hold.container as? PooledEmbedding)?.dimension`), because `PooledEmbedder` has none. `RoutedEmbedder.dimension` keeps working from that value.
- Call `embed(texts:)`.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [ ] The Router has no code that makes an MLX embedder itself.
- [ ] `profile.embedding.dimension` still gives the model dimension after resolve.
- [ ] A Router resolve and a `PooledEmbedder` with the same name in one process share one resident model.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ExtrasPoolResolveTests.swift`: resolve, then `PooledEmbedder(ref: sameName).embed(texts:)` does not load again (with `ModelPool(loader:)` and a test loader).
- [ ] Update `SlotPoolLoaderTests.swift` for the delegating loader.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool