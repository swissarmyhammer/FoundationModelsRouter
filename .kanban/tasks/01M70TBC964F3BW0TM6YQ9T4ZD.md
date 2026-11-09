---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m70xjjvhnwj4yjhg9pxn0qtj
  text: |-
    Implemented (uncommitted):
    - `MLXFoundationModelsContainer` → `LiveLLMContainer`, which holds `any LanguageModel`. The executor configuration compares the wrapped model's configuration as `any Hashable & Sendable`.
    - `LiveLLMContainer.make(wrappingLoaded:ref:)` dispatches MLX vs llama and returns nil for other types. The name is deliberately distinct from `make(wrapping:)`: an overload with the same name resolved to itself inside the switch (infinite async recursion → jetsam SIGKILL).
    - The llama container: window = `LlamaLanguageModel.contextSize`, token counter = new `LlamaTokenCounter` over `LlamaTokenizer` (FoundationModelsLlamaCpp a082eff).
    - `LiveModelLoaderError.notAnMLXLanguageModel` → `unsupportedGenerationModel`.
    - `LiveLLMContainer.mlxModel` lets the integration tests evict and inspect the MLX model.
    - 4 hermetic tests over the vocab-only qwen35 fixture (LiveLLMContainerGGUFTests). Root suite: 2449 pass. The IntegrationTests package builds.

    MLX-only for now (llama has no equivalent yet): `ReasoningSwitchable` (reasoning off for one call is skipped, which the backend already handles for a model that can't switch), `SessionPromptCacheScoping`/`Releasing` (llama manages its own cache tiers). The speculative-decoding metadata keys match, so `GenerationCallUsage.speculativeDecoding` reads llama responses unchanged; the real-model test will verify it.
  timestamp: 2026-11-09T19:46:45.745358+00:00
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: review
position_ordinal: '8180'
title: 'GGUF: a generation container over LlamaLanguageModel'
---
## What
`LiveModelLoader.loadGeneration` accepts only an `MLXLanguageModel`. Anything else throws `LiveModelLoaderError.notAnMLXLanguageModel` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift ~1140). Make it accept a `LlamaLanguageModel` too.

`MLXFoundationModelsSessionBackend` already holds `any FoundationModels.LanguageModel`. Only `MLXFoundationModelsContainer` (`let model: MLXLanguageModel`) and its `make(wrapping:ref:)` are tied to MLX, because they read the context window from config.json and the token counter from the MLX tokenizer. Generalize the container over the model (or add a llama container next to it):
- contextWindow: the context the model was loaded with (`LlamaLanguageModel.Options.contextSize`). See the context-at-load task.
- tokenCounter: over `LlamaLanguageModel.tokenCount(for:)`.
- Replace `notAnMLXLanguageModel` with an error that names both supported types.
- Check each MLX-only feature of the backend against llama, keep the ones it supports, and leave a note for the others: `ReasoningSwitchable` (reasoning off for one call), `SessionPromptCacheScoping`/`SessionPromptCacheReleasing`, `GenerationPassReporting`, eviction through the model loader, and the `SpeculativeDecodingOutcome` read (llama emits the same 4 metadata keys, so `GenerationCallUsage.speculativeDecoding` should fill unchanged).

## Acceptance
- [ ] A hermetic test: the loader wraps a LlamaLanguageModel built over a vocab-only GGUF from LlamaCppTestFixtures, and a session can be made.
- [ ] No MLX-only cast remains on the generation path, apart from the features marked as MLX-only. #gguf