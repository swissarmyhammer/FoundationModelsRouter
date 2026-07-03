---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwkw0mn787zvanyqhfdvtra0
  text: |-
    Implemented via TDD-style RED/GREEN on the build gate:

    RED: confirmed `swift build --target MultiModelGeneration` failed with "Could not find target named 'MultiModelGeneration'" before any changes.

    GREEN:
    - Package.swift: added `.executableTarget(name: "MultiModelGeneration", dependencies: [.target(name: packageName)] + mlxProducts + hubProducts, path: "Examples/MultiModelGeneration", exclude: ["README.md"])`. No new `.package` dependencies; reuses existing `mlxProducts`/`hubProducts` constants. `exclude: ["README.md"]` avoids an "unhandled resource" build warning.
    - Examples/MultiModelGeneration/main.swift: live twin of `ExamplesTests.multiModelDirectGeneration()`. Constructs `Router(recordingsDir:loader:)` with `LiveModelLoader(downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader())`; authors a `ProfileDefinition` with distinct model refs (`flash: mlx-community/SmolLM-135M-Instruct-4bit`, `standard: mlx-community/Qwen2.5-3B-Instruct-4bit`, `embedding: mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`); resolves once with a `ResolutionProgress` polled by a background `Task` printing phase/fraction transitions; drives a triage turn on `profile.flash.makeSession(...).respond(to:)`, then a streamed answer on `profile.standard.makeSession(...).streamResponse(to:)` printed fragment by fragment; calls `await profile.release()` at the end.
    - Examples/MultiModelGeneration/README.md: two-line description + `swift run MultiModelGeneration` run command, noting first-run download + Apple silicon/network requirement.

    Verification (fresh runs):
    - `swift build --target MultiModelGeneration` — exit 0, zero warnings from this change (only the pre-existing, unrelated "missing creator for mutated node" mlx-swift Cmlx warning, confirmed present even when building the bare `FoundationModelsRouter` library target on its own).
    - `swift build` (whole package) — exit 0, same pre-existing warning only.
    - `swift test` — 129/129 unit tests pass; gated integration suite correctly skipped (no `FM_ROUTER_INTEGRATION_TESTS` env var).
    - `git diff --stat` confirms the only source changes are Package.swift's new target entry plus the new Examples/ directory — library and both existing test targets untouched.
    - Adversarial double-check agent (via really-done): PASS, no findings — confirmed every API call in main.swift matches the real signatures in Router.swift/LanguageModelProfile.swift/RoutedLLM.swift/RoutedSession.swift/ResolutionProgress.swift/LiveModelLoader.swift, two genuinely distinct model refs used, profile released, no scope creep.

    All acceptance criteria and test checkboxes satisfied. Leaving in `doing` for `/review` per the implement skill contract.
  timestamp: 2026-07-03T11:32:23.335394+00:00
depends_on:
- 01KWKRK11ADWX13C394RYJ9BBH
position_column: doing
position_ordinal: '80'
title: Add runnable Examples/ folder with a multi-model direct generation executable
---
# Add runnable Examples/ folder with a multi-model direct generation executable

## What

Give the package a conventional `Examples/` folder holding a real, runnable demo of the multi-model direct-generation story (the live twin of the offline example added by `^ryj9bbh`): one `Router.resolve` makes two local generation models co-resident, the program routes a quick turn to `profile.flash` and a heavyweight turn to `profile.standard`.

- [x] In `Package.swift`, add an `.executableTarget(name: "MultiModelGeneration", path: "Examples/MultiModelGeneration")` depending on the `FoundationModelsRouter` target plus the existing `mlxProducts` and `hubProducts` constants (the live loader needs `#hubDownloader()` / `#huggingFaceTokenizerLoader()` from `MLXHuggingFace`, backed by the `HuggingFace` and `Tokenizers` products). **No new package dependencies** — `hubProducts` is already declared for the gated integration test target; reuse those constants.
- [x] Create `Examples/MultiModelGeneration/main.swift` (executable entry point) that mirrors the production pattern already proven in `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`:
  - Construct `Router(recordingsDir:loader:)` with `LiveModelLoader(downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader())` — real downloads, real MLX inference.
  - Author a `ProfileDefinition` with **distinct, deliberately small model refs per generation slot** so both co-fit and the multi-model point is visible — e.g. flash: `mlx-community/SmolLM-135M-Instruct-4bit` (the integration suite's tiny generation model), standard: a modest step up such as `mlx-community/Qwen2.5-3B-Instruct-4bit`, plus the tiny embedding ref `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
  - Resolve once with a `ResolutionProgress`, printing phase/fraction so a first-time user sees download → load → ready.
  - Drive `profile.flash.makeSession(...)` for a short triage turn, then stream the long answer from `profile.standard.makeSession(...)` fragment-by-fragment to stdout; print which `chosen` model served each turn; `await profile.release()` at the end.
  - Comment the file in the same narrative, doc-style voice as `ExamplesTests.swift` so it doubles as documentation.
- [x] Add `Examples/MultiModelGeneration/README.md` with a two-line description and the run command (`swift run MultiModelGeneration`), noting it downloads models on first run and needs Apple silicon + network (same constraints as the gated integration suite).

## Acceptance Criteria

- [x] `Package.swift` declares the `MultiModelGeneration` executable target at `Examples/MultiModelGeneration`, reusing the existing `mlxProducts`/`hubProducts` constants; the manifest adds no new `.package` dependencies.
- [x] `swift build --target MultiModelGeneration` compiles the example on a plain checkout (compilation does not require network beyond dependency fetch, GPU, or model downloads).
- [x] The example source uses two different generation model refs for `standard` and `flash` and exercises both slots via direct generation (`respond`/`streamResponse`) from one resolved profile, releasing the profile before exit.
- [x] The library and both existing test targets are untouched apart from the manifest's new target entry.

## Tests

- [x] Automated build gate: `swift build --target MultiModelGeneration` succeeds — this compiles the example in the same `swift build` CI already runs (actually executing it downloads real models, which stays out of ungated CI by design, mirroring the gated integration suite).
- [x] `swift test` — full unit suite stays green (no regression from the manifest change).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.