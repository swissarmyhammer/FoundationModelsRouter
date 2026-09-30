---
position_column: todo
position_ordinal: '80'
title: Load models through the Extras built-in loader; delete the Router copy of the MLX load code
---
**Wait for:** the FoundationModelsExtras tasks "PooledEmbedder from a Hugging Face name" (01M3QKWR26HVCVNR8KWWRQCCDQ) and "PooledModel and PooledSession for an LLM by Hugging Face name" (01M3QKWR7DD80PS72KHT2H3THF) on the Extras board must be done and pushed first.

## What
There must be one MLX loader in the family: the Extras built-in loader. The Router keeps profiles, resolve, slots, sizing and its session layer.

- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` (1,177 lines): remove its own MLX load code for both roles: `loadGeneration`'s `MLXLanguageModel` construction, `loadEmbedding`, `LiveEmbeddingContainer` (line ~795). Get the loaded model from the Extras pool (`ModelPool.acquire(_ key:)`, which uses the built-in loader), and wrap the `MLXLanguageModel` of the hold in `MLXFoundationModelsContainer` as now.
- `Sources/FoundationModelsRouter/Resolution/PooledEmbeddingContainer.swift`: use `PooledEmbedder(ref, pool:)` (name-based) in place of `PooledEmbedder(hold:)`. Then delete `PooledEmbedder.init(hold:)` in Extras if no other caller remains.
- Delete `Sources/FoundationModelsRouter/Resolution/PaddedTokenBatch.swift` if only the deleted embedding code used it.
- Keep the Router download-progress reporting by mapping `ModelPool.progress(for:)` to `DownloadProgress` / `ResolutionProgress`.
- Keep the capabilities `[.guidedGeneration, .toolCalling, .reasoning]` (the Extras loader already declares them).

## Acceptance Criteria
- [ ] The Router has no code that makes an `MLXLanguageModel` or an MLX embedder container itself.
- [ ] A Router resolve of a profile and a `PooledModel`/`PooledEmbedder` with the same names in one process share one resident model each (one load).
- [ ] Resolution progress still reports downloading/loading/ready.
- [ ] All Router tests pass.

## Tests
- [ ] Update `Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift`, `ExtrasPoolResolveTests.swift` and `PromptCacheBudgetTests.swift` for the Extras loader.
- [ ] New test in `ExtrasPoolResolveTests.swift`: resolve, then `PooledEmbedder(sameName).embed` does not load again (with an injected Extras test loader).
- [ ] `IntegrationTests/.../CrossRouterPoolIntegrationTests.swift`: real resolve + `PooledModel` on the same name share one resident model.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool