---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3sa33tc5h6x9hkv78kebdr6
  text: 'Research: no source under IntegrationTests/Tests imports HuggingFace, Tokenizers, MLXHuggingFace, MLXLLM, MLXVLM, MLXEmbedders or MLXGuidedGeneration. The integration target imports MLXLMCommon and MLXFoundationModels. The eval target imports only MLXLMCommon. The root library target links the full MLX list (with the MLXLLM and MLXVLM factories that ModelFactoryRegistry finds with NSClassFromString), so the test binaries get those factories through the router product. The root manifest pins swift-transformers, and swift-huggingface comes in through Extras and mlx-swift-lm, so the nested manifest does not have to restate either pin. Decision: remove hubProducts, both Hugging Face package dependencies, and the MLX products that no target imports. Each target now links only the MLX products that its sources import. `swift package --package-path IntegrationTests --manifest-cache local resolve` (after the sourcekit-lsp of this repo was stopped) left both Package.resolved files unchanged. Note: a `swift test` call through the sah shell for more than about 30 minutes aborts on the client side. Run the real-model tiers with nohup and a log file.'
  timestamp: 2026-09-30T14:04:29.388323+00:00
- actor: claude-code
  id: 01m3sdtg4998dkftv9y7zszpm6
  text: |-
    ### implement — changed
    - evidence: 1 file — IntegrationTests/Package.swift (removed hubProducts, the swift-huggingface and swift-transformers package dependencies, and the MLX products MLXLLM, MLXVLM, MLXEmbedders, MLXHuggingFace and MLXGuidedGeneration that no target imports; the integration target links MLXLMCommon + MLXFoundationModels, the eval target links MLXLMCommon). Package.resolved files unchanged. `swift build --package-path IntegrationTests --build-tests`: Build complete, no compiler warning (only the known SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", present before this change). `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests`: 49 tests in 22 suites passed (2571.9 s). `--filter FoundationModelsRouterEvalIntegrationTests`: 1 test in 1 suite passed (316.2 s). No skipped test, no known issue.
    - next: /review
  timestamp: 2026-09-30T15:09:41.385084+00:00
- actor: claude-code
  id: 01m3se5dheb2zjn47kdtmvptwx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (10940a5): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. IntegrationTests/Package.swift reviewed. 4 .kanban files excluded by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-09-30T15:15:39.182239+00:00
position_column: done
position_ordinal: ffffffbc80
title: Remove the unused Hub client and tokenizer products from the IntegrationTests manifest
---
## What
- `IntegrationTests/Package.swift` links `hubProducts` (`HuggingFace`, `Tokenizers`) into each real-model target. Its comment says the targets use them "to construct a live `LiveModelLoader` through the `MLXHuggingFace` macros".
- No source file under `IntegrationTests/Tests` imports `HuggingFace`, `Tokenizers` or `MLXHuggingFace`, and none expands `#hubDownloader()` or `#huggingFaceTokenizerLoader()`. `LiveModelLoader()` loads through the Extras `MLXModelLoader`, and the RealModelSupport product links `Tokenizers` itself (task ^8c10hfb).
- Remove `hubProducts` and the `swift-huggingface` package dependency from the IntegrationTests manifest if nothing needs them. Keep `swift-transformers` only if the manifest must restate the pin of the root package.

## Acceptance Criteria
- [x] The IntegrationTests manifest links no product that no target uses.
- [x] `swift test --package-path IntegrationTests` builds with no new warning and passes.

## Tests
- [x] `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests` and `--filter FoundationModelsRouterEvalIntegrationTests` pass, with non-zero test counts. #model-pool