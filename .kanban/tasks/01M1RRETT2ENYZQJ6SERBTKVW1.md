---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Fork: key the MLXLanguageModel cache by id and revision, then bump Package.resolved'
---
Plan: `model-pool.md` §1.4, §2.6.

## What
In the fork `swissarmyhammer/mlx-swift-lm` (branch `stable`), `MLXLanguageModel.modelID` is `configuration.name`, which is the repo id alone. The process-global `ModelCache` in `Libraries/MLXFoundationModels/MLXLanguageModel.swift` is keyed by that id, so two configurations for one repo at two revisions share one `ModelContainer`. The second caller gets the first revision's weights.

Work in a separate clone of `https://github.com/swissarmyhammer/mlx-swift-lm`, not in `IntegrationTests/.build/checkouts/mlx-swift-lm`. That directory is a SwiftPM artifact, detached at the pinned revision `41e9f41c`, and `swift package resolve` discards edits there.

- In the fork, make `MLXLanguageModel.modelID` include the revision for `.id(id, revision:)` when the revision is not `"main"`: `"\(id)@\(revision)"`. For `.directory(url)` keep `configuration.name`. Keep `ModelConfiguration.name` unchanged; download progress already passes `configuration.name`.
- Change the two `weightsLocation(modelID)` call sites in `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift` (lines 143 and 182 at `41e9f41c`) to pass `configuration.name`, so on-disk resolution keeps receiving a path-shaped id.
- Audit the other `modelID` uses: `ModelCache` keys, `ExecutorPromptCacheStore`, and `lastError`/`isDownloading`. All of them are cache identity and want the revision.
- Push to `stable`. Then, here: bump `Package.resolved` and `IntegrationTests/Package.resolved` to the new fork revision, and check `LiveModelLoader.weightsLocation` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`) still resolves in the gated suites.

## Acceptance Criteria
- [ ] In the fork, two `MLXLanguageModel` values for one id at two revisions have two `modelID` values, two cache entries, and two container loads.
- [ ] In the fork, `evict()` on one revision leaves the other revision cached.
- [ ] In the fork, `modelExistsOnDisk()` still resolves through `configuration.name`.
- [ ] Both `Package.resolved` files here pin the fork revision that carries the fix.
- [ ] `swift test` and `swift test --package-path IntegrationTests` are green here.

## Tests
- [ ] Fork: new test in `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift`, placed under the `@Suite(.serialized)` parent that `ModelCacheEvictionTests` documents (the cache is one process-global `static let`): configurations `(id: "org/repo", revision: "a")` and `(id: "org/repo", revision: "b")` give two distinct `modelID` values and two `loadContainer()` calls on a stub loader; `evict()` on one leaves the other.
- [ ] Fork: `swift test --filter MLXLanguageModelTests` → all pass.
- [ ] Here: `swift test` → all pass. `swift test --package-path IntegrationTests` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #defect