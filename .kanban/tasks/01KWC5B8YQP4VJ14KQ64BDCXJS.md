---
position_column: todo
position_ordinal: '80'
title: Bootstrap Swift package + MLX fork dependency
---
## What
Create the SwiftPM package that everything else builds on. Greenfield — no `Package.swift` exists yet.

- Create `Package.swift` (swift-tools 6.x):
  - `platforms: [.macOS("27.0")]` — commit to macOS 27 / FoundationModels v2; no pre-27 fallback.
  - Dependency on the controlled fork (branch dep, pinned via `Package.resolved`):
    `.package(url: "https://github.com/swissarmyhammer/mlx-swift-lm", branch: "mlx-foundationmodels")`
  - Library target `FoundationModelsRouter` depending on the MLX products it needs: `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration` (confirm exact product names from the fork's `Package.swift` at tip `234787d`).
  - Test target `FoundationModelsRouterTests` using Swift Testing (`import Testing`).
  - A separate `FoundationModelsRouterIntegrationTests` target placeholder for the gated, real-model suite (milestone 7).
- Create `Sources/FoundationModelsRouter/` with a trivial `FoundationModelsRouter.swift` (module marker) and the directory layout the plan implies (`Core/`, `Sizing/`, `Resolution/`, `Session/`, `Concurrency/`, `Guided/`, `Recording/`).
- Confirm `import MLXLMCommon`, `import MLXEmbedders`, `import MLXFoundationModels`, `import MLXGuidedGeneration` all compile.

## Acceptance Criteria
- [ ] `swift build` resolves the fork on branch `mlx-foundationmodels` and compiles.
- [ ] `Package.resolved` pins the fork to a specific commit.
- [ ] A smoke test that `@testable import FoundationModelsRouter` and the MLX modules compiles and runs.
- [ ] `.gitignore` already covers `.build/` and `Package.resolved` policy is decided (commit it to pin the branch dep).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/BootstrapTests.swift` — a Swift Testing `@Test` that imports the module and the MLX products and asserts a trivial fact (compilation is the real assertion).
- [ ] Run `swift build && swift test` — both succeed.

## Workflow
- Use `/tdd` — write the failing import/build smoke test first, then make it pass.