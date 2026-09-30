---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Remove the unused Hub client and tokenizer products from the IntegrationTests manifest
---
## What
- `IntegrationTests/Package.swift` links `hubProducts` (`HuggingFace`, `Tokenizers`) into each real-model target. Its comment says the targets use them "to construct a live `LiveModelLoader` through the `MLXHuggingFace` macros".
- No source file under `IntegrationTests/Tests` imports `HuggingFace`, `Tokenizers` or `MLXHuggingFace`, and none expands `#hubDownloader()` or `#huggingFaceTokenizerLoader()`. `LiveModelLoader()` loads through the Extras `MLXModelLoader`, and the RealModelSupport product links `Tokenizers` itself (task ^8c10hfb).
- Remove `hubProducts` and the `swift-huggingface` package dependency from the IntegrationTests manifest if nothing needs them. Keep `swift-transformers` only if the manifest must restate the pin of the root package.

## Acceptance Criteria
- [ ] The IntegrationTests manifest links no product that no target uses.
- [ ] `swift test --package-path IntegrationTests` builds with no new warning and passes.

## Tests
- [ ] `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests` and `--filter FoundationModelsRouterEvalIntegrationTests` pass, with non-zero test counts. #model-pool