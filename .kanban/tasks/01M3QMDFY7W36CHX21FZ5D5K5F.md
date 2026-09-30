---
depends_on:
- 01M3QMDDGWZ7CRAE1P3JKFP5FP
position_column: todo
position_ordinal: '8180'
title: Generation models load through the Extras MLXModelLoader; map pool progress to resolution progress
---
**Wait for:** FoundationModelsExtras tasks 01M3QMD6V09WGE7MJDV483VHBG ("Built-in MLX loader in the core…") and 01M3QMD7BY8SYK3EGAMG8M6X1Y ("Load progress stream on the model pool") on the Extras board: done and pushed.

## What
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: `loadGeneration` gets its `MLXLanguageModel` from `MLXModelLoader().load(key)` in place of making it; the Router wraps it in `MLXFoundationModelsContainer` as now (queue, token counter, context window stay Router code).
- Download progress: map `ModelPool.progress(for:)` to `DownloadProgress` / `ResolutionProgress`, so resolve still reports downloading → loading → ready.
- Keep `acquire(_:footprintBytes:sessionBytes:loader:)` with the Router sizing and admission (`SlotPoolLoader`, `PromptCacheSizing`).
- Delete the Router code that only the old load path used.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [ ] The Router has no code that constructs an `MLXLanguageModel`.
- [ ] A Router resolve and a `PooledModel` with the same name in one process share one resident model.
- [ ] Resolution progress still reports downloading, loading and ready.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ExtrasPoolResolveTests.swift`: resolve, then `PooledModel(ref: sameName).session` does not load again.
- [ ] A resolution-progress test with a test loader that reports progress.
- [ ] `IntegrationTests/.../CrossRouterPoolIntegrationTests.swift`: real resolve + `PooledModel` on one name share one resident model.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool