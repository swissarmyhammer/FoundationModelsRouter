---
comments:
- actor: wballard
  id: 01kwcjmz03rzkjmznx6whgcryd
  text: 'Picked up by /finish (scoped-batch, first ready task). Host verified: Swift 6.4, macOS 27.0, arm64 — stack is buildable here. Iteration 1: delegating to /implement. Note: this task resolves the swissarmyhammer/mlx-swift-lm `mlx-foundationmodels` branch dep (PR #334, pre-merge) and needs network access to fetch it.'
  timestamp: 2026-06-30T15:34:02.499496+00:00
- actor: wballard
  id: 01kwck10kxgvw1fxy8gddywrgt
  text: |-
    GREEN in doing. Bootstrap complete via TDD (wrote BootstrapTests import smoke test, watched it fail on missing sources, then created Package.swift + module).

    Built:
    - Package.swift (swift-tools 6.1), platforms [.macOS(\"27.0\")], branch dep on swissarmyhammer/mlx-swift-lm@mlx-foundationmodels. All 6 MLX product names confirmed against the fork's Package.swift and verified to compile: MLXLMCommon, MLXLLM, MLXEmbedders, MLXHuggingFace, MLXFoundationModels, MLXGuidedGeneration. Fork uses a default-on package trait `FoundationModelsIntegration` (gates MLXFoundationModels on macOS 27) — picked up automatically via default traits.
    - Sources/FoundationModelsRouter/FoundationModelsRouter.swift (module marker: `public let moduleName`). Plan dir layout created: Core/ Sizing/ Resolution/ Session/ Concurrency/ Guided/ Recording/ each with a .gitkeep (SwiftPM emits no unhandled-files warning for them).
    - Tests/FoundationModelsRouterTests/BootstrapTests.swift (Swift Testing @Test: @testable import + all 6 MLX imports; compilation is the real assertion).
    - Tests/FoundationModelsRouterIntegrationTests/ placeholder target (one .disabled @Test, gated suite lands in milestone 7).
    - Package.resolved committed (un-ignored in .gitignore); pins mlx-swift-lm to revision e6ccd2721ab3b236b92e436bee2130086f48041c. (Note: task mentioned tip 234787d; current branch HEAD is e6ccd27.)

    CRITICAL ENV NOTE for next agent / CI: the active developer dir is Command Line Tools, which has no `metal` compiler, so a bare `swift build` FAILS compiling mlx-swift's Metal shaders (error: unable to spawn process 'metal'). Fix applied: build/test with `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`, AND the Metal Toolchain component had to be downloaded once via `xcodebuild -downloadComponent MetalToolchain` (838MB, no sudo needed). With that in place both succeed:
    - `swift build` -> Build complete (exit 0).
    - `swift test` -> 1 test passed (Bootstrap), 1 skipped (Integration placeholder), 0 failures.
    Only build warning is from the upstream mlx-swift bundle graph (\"missing creator for mutated node\"), not our package.
  timestamp: 2026-06-30T15:40:37.373123+00:00
- actor: wballard
  id: 01kwck5wmxwnepk3282k8cpgcb
  text: 'really-done: adversarial double-check returned PASS. All 7 acceptance criteria verified against a fresh green `swift build` + `swift test` (with DEVELOPER_DIR set). Two advisory notes, both non-defects: (1) the whole package is still untracked in git — the commit step must explicitly `git add` Package.swift, Package.resolved, Sources/ (incl .gitkeep files), Tests/, and the .gitignore change, since `git commit -am` would miss untracked files; (2) pinned commit e6ccd27 differs from plan.md''s cited tip 234787d — expected, Package.resolved correctly pins the current branch HEAD. Task is GREEN, left in `doing` for /review.'
  timestamp: 2026-06-30T15:43:17.149713+00:00
- actor: wballard
  id: 01kwck7j76exta33fhm3155x2d
  text: |-
    Iteration 1 implement landed GREEN in doing (double-check PASS). `swift build` → Build complete; `swift test` → 1 passed, 1 skipped (integration placeholder), 0 failures. Pinned mlx-swift-lm @ e6ccd27.

    CRITICAL BUILD ENV (applies to every future task in this repo): a bare `swift build` FAILS — active xcode-select is CommandLineTools which lacks `metal`, so mlx-swift Metal shaders won't compile. Must `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (Metal Toolchain already downloaded on this host). Test gate for this iteration = implementer's fresh green swift test. Proceeding to checkpoint commit + review.
  timestamp: 2026-06-30T15:44:12.006323+00:00
- actor: wballard
  id: 01kwcksv42ky4t50y9g2yzn922
  text: Resolved all 12 review findings. Package.swift now declares two top-level constants (let mlxPackage = "mlx-swift-lm", let packageName = "FoundationModelsRouter") and references them everywhere — product packages, dependency URL (interpolated), package/library/target names, and all path + test-target-name strings (interpolated). grep of Package.swift finds the literals only in their two declarations. swift build green, swift test green (Bootstrap import/link test passed; integration test skipped as designed). Package.resolved unchanged — resolution identical.
  timestamp: 2026-06-30T15:54:10.946712+00:00
position_column: done
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

## Review Findings (2026-06-30 10:45)

- [x] `Package.swift:10` — The package name "mlx-swift-lm" is hardcoded and repeated 6 times in the mlxProducts array (lines 10-15), creating maintenance burden if the dependency name changes. Extract to a named constant: let mlxPackageName = "mlx-swift-lm" and reuse it in each product.
- [x] `Package.swift:11` — Repeated package name literal; part of the 6-fold repetition of "mlx-swift-lm". Use the extracted named constant.
- [x] `Package.swift:12` — Repeated package name literal; part of the 6-fold repetition of "mlx-swift-lm". Use the extracted named constant.
- [x] `Package.swift:13` — Repeated package name literal; part of the 6-fold repetition of "mlx-swift-lm". Use the extracted named constant.
- [x] `Package.swift:14` — Repeated package name literal; part of the 6-fold repetition of "mlx-swift-lm". Use the extracted named constant.
- [x] `Package.swift:15` — Repeated package name literal; part of the 6-fold repetition of "mlx-swift-lm". Use the extracted named constant.
- [x] `Package.swift:19` — The package name "FoundationModelsRouter" is hardcoded and repeated 6 times throughout the Package definition (lines 19, 26, 27, 38, 44, 51), creating maintenance burden if the package name changes. Extract to a named constant at the top of the file and reuse it.
- [x] `Package.swift:26` — Repeated package name literal; part of the 6-fold repetition of "FoundationModelsRouter". Use the extracted named constant.
- [x] `Package.swift:27` — Repeated package name literal; part of the 6-fold repetition of "FoundationModelsRouter". Use the extracted named constant.
- [x] `Package.swift:38` — Repeated package name literal; part of the 6-fold repetition of "FoundationModelsRouter". Use the extracted named constant.
- [x] `Package.swift:44` — Repeated package name literal; part of the 6-fold repetition of "FoundationModelsRouter". Use the extracted named constant.
- [x] `Package.swift:51` — Repeated package name literal; part of the 6-fold repetition of "FoundationModelsRouter". Use the extracted named constant.

## Resolution (2026-06-30)
Extracted two top-level `let` constants in `Package.swift` — `let mlxPackage = "mlx-swift-lm"` and `let packageName = "FoundationModelsRouter"` — and referenced them at every site, including the dependency URL and all target/path names via string interpolation. A grep of `Package.swift` now finds the literals ONLY in their two constant declarations (zero recurrences elsewhere). `swift build` and `swift test` both green; `Package.resolved` unchanged (same package, same products — resolution unaffected).