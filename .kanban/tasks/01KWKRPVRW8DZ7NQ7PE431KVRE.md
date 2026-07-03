---
assignees:
- claude-code
depends_on:
- 01KWKRK11ADWX13C394RYJ9BBH
position_column: todo
position_ordinal: '8180'
title: Add runnable Examples/ folder with a multi-model direct generation executable
---
# Add runnable Examples/ folder with a multi-model direct generation executable

## What

Give the package a conventional `Examples/` folder holding a real, runnable demo of the multi-model direct-generation story (the live twin of the offline example added by `^ryj9bbh`): one `Router.resolve` makes two local generation models co-resident, the program routes a quick turn to `profile.flash` and a heavyweight turn to `profile.standard`.

- [ ] In `Package.swift`, add an `.executableTarget(name: "MultiModelGeneration", path: "Examples/MultiModelGeneration")` depending on the `FoundationModelsRouter` target plus the existing `mlxProducts` and `hubProducts` constants (the live loader needs `#hubDownloader()` / `#huggingFaceTokenizerLoader()` from `MLXHuggingFace`, backed by the `HuggingFace` and `Tokenizers` products). **No new package dependencies** — `hubProducts` is already declared for the gated integration test target; reuse those constants.
- [ ] Create `Examples/MultiModelGeneration/main.swift` (executable entry point) that mirrors the production pattern already proven in `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`:
  - Construct `Router(recordingsDir:loader:)` with `LiveModelLoader(downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader())` — real downloads, real MLX inference.
  - Author a `ProfileDefinition` with **distinct, deliberately small model refs per generation slot** so both co-fit and the multi-model point is visible — e.g. flash: `mlx-community/SmolLM-135M-Instruct-4bit` (the integration suite's tiny generation model), standard: a modest step up such as `mlx-community/Qwen2.5-3B-Instruct-4bit`, plus the tiny embedding ref `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
  - Resolve once with a `ResolutionProgress`, printing phase/fraction so a first-time user sees download → load → ready.
  - Drive `profile.flash.makeSession(...)` for a short triage turn, then stream the long answer from `profile.standard.makeSession(...)` fragment-by-fragment to stdout; print which `chosen` model served each turn; `await profile.release()` at the end.
  - Comment the file in the same narrative, doc-style voice as `ExamplesTests.swift` so it doubles as documentation.
- [ ] Add `Examples/MultiModelGeneration/README.md` with a two-line description and the run command (`swift run MultiModelGeneration`), noting it downloads models on first run and needs Apple silicon + network (same constraints as the gated integration suite).

## Acceptance Criteria

- [ ] `Package.swift` declares the `MultiModelGeneration` executable target at `Examples/MultiModelGeneration`, reusing the existing `mlxProducts`/`hubProducts` constants; the manifest adds no new `.package` dependencies.
- [ ] `swift build --target MultiModelGeneration` compiles the example on a plain checkout (compilation does not require network beyond dependency fetch, GPU, or model downloads).
- [ ] The example source uses two different generation model refs for `standard` and `flash` and exercises both slots via direct generation (`respond`/`streamResponse`) from one resolved profile, releasing the profile before exit.
- [ ] The library and both existing test targets are untouched apart from the manifest's new target entry.

## Tests

- [ ] Automated build gate: `swift build --target MultiModelGeneration` succeeds — this compiles the example in the same `swift build` CI already runs (actually executing it downloads real models, which stays out of ungated CI by design, mirroring the gated integration suite).
- [ ] `swift test` — full unit suite stays green (no regression from the manifest change).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.