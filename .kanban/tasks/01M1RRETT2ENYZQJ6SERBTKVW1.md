---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1savx1v3fa04jzb0q0xry57
  text: |-
    Research on the fork clone (branch `stable`, head `0147840`, the same sha both `Package.resolved` files here pin):
    - `MLXLanguageModel.modelID` is `configuration.name` (`MLXLanguageModel.swift:376`). The `ModelCache` actor keys `containers`, `loadingTasks`, `suppressedLoadIDs`, `xgTokenizers`, `constraintTemplates` (prefix `modelID:`), `tokenizerBiases`, and `lastErrors` by it. `Executor.Configuration(modelID:)`, `ExecutorPromptCacheKey.modelID`, and `ExecutorPromptCacheStore.evict(modelID:)` use it too. All of these are cache identity and keep the new value.
    - `weightsLocation(modelID)` has two call sites, in `MLXLanguageModel+Availability.swift` at `freeDiskSpaceBytes` (line 143) and `modelExistsOnDisk()` (line 182). Download progress already passes `configuration.name`.
    - The fork's `CLAUDE.md` says: do not use `swift test`, it stops at the first GPU test with `MLX error: Failed to load the default metallib` (the `swiftpm-testing-helper` opens the bundle with `dlopen`, so the mlx loader cannot find `mlx-swift_Cmlx.bundle`). The documented procedure is `swift build --build-tests`, then `xcrun xctest .build/out/Products/Debug/<Bundle>.xctest` for each of the five bundles. I confirmed the `swift test --filter` failure here, and I use the documented procedure for the card's test steps.
    - Test helpers that already exist and that the new tests reuse: `makeScriptedContainer(modelID:rounds:)` and `makeScriptedWeightsDirectory()` in `ScriptedModelTestSupport.swift`, `stubLoad()` in `TestHelpers.swift`, and the serialized parent `FoundationModelsCacheTests` in `ModelCacheEvictionTests.swift`.
    - Here, `Package.resolved` is in `.gitignore` (both files are untracked), so the pin bump is a local resolve, not a tracked change.
  timestamp: 2026-09-05T17:46:38.011800+00:00
- actor: claude-code
  id: 01m1sb8568x8fz8g9vd14entj7
  text: |-
    Fork half done. Commit `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb` (`fix(foundation-models): key the model cache by id and revision`) is pushed to `stable` on `swissarmyhammer/mlx-swift-lm` (`0147840..18ddcd1`).
    - Files: `Libraries/MLXFoundationModels/MLXLanguageModel.swift` (`modelID` is `"<id>@<revision>"` for a Hub model at a revision other than `main`; `defaultRevision` constant; doc of `weightsLocation`), `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift` (both `weightsLocation` call sites pass `configuration.name`), `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift` (suite `RevisionIdentity` under the serialized `FoundationModelsCacheTests` parent: six tests).
    - TDD: the new tests failed first with the expected reasons (`modelA.modelID == "org/repo@a"` false, one load for two revisions, `modelExistsOnDisk()` saw the cache key), then passed after the change.
    - Fork tests, with the procedure the fork's `CLAUDE.md` gives (`swift build --build-tests`, then `xcrun xctest` per bundle): MLXFoundationModelsTests 173 passed; MLXLMTests 640 XCTest (1 skipped: `testRealCheckpointBenchmark`, a pre-existing skip that needs `MLX_QWEN_GDN_BENCH_MODEL`) and 996 Swift Testing passed; MLXGuidedGenerationTests 70; CXGrammarTests 7; MLXHuggingFaceMacrosTests 5. Zero failures.
    - Push note: `git push origin stable` over HTTPS hung at `git credential-osxkeychain get` (a keychain prompt with no terminal). I stopped that process and pushed over SSH (`git push git@github.com:swissarmyhammer/mlx-swift-lm.git HEAD:stable`), which `gh auth status` names as the configured git protocol.
  timestamp: 2026-09-05T17:53:19.560629+00:00
- actor: claude-code
  id: 01m1sc1971eg1j7teqy6d35jp7
  text: |-
    Repository half done. `Package.resolved` is git-ignored here, so the bump is local: `swift package update mlx-swift-lm` (root) and `swift package --package-path IntegrationTests update mlx-swift-lm` (the `--package-path` option must come before `update` in this toolchain). Both `Package.resolved` files and both `.build/checkouts/mlx-swift-lm` working copies now sit at `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb`. No tracked file changed apart from `.kanban/`.
    - `swift test` (root): 1235 tests in 134 suites passed with 2 known issues (pre-existing `withKnownIssue` marks), plus 83 XCTest tests in 10 suites passed.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `swift test --package-path IntegrationTests` (gated, real models): 36 tests in 18 suites passed after 665 s, plus 2 tests in 2 suites passed after 68 s. `LiveModelLoader.weightsLocation` resolves as before, because the fork passes `configuration.name` to it.

    ### implement — changed
    - evidence: fork commit `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb` pushed to `stable` (3 files: `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift`, `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift`); here, both `Package.resolved` files (untracked) and both checkouts moved to that sha; tracked changes here: `.kanban/` only
    - next: test
  timestamp: 2026-09-05T18:07:02.881973+00:00
- actor: claude-code
  id: 01m1sc21avptfqzmbnvghvk4aw
  text: |-
    ### test — green
    - evidence: fork (`swift build --build-tests` + `xcrun xctest` per bundle): MLXFoundationModelsTests 173 passed; MLXLMTests 640 XCTest (1 pre-existing skip, `testRealCheckpointBenchmark`, gated by `MLX_QWEN_GDN_BENCH_MODEL`, recorded as a new card) + 996 Swift Testing passed; MLXGuidedGenerationTests 70; CXGrammarTests 7; MLXHuggingFaceMacrosTests 5. Root `swift test`: 1235 passed in 134 suites (2 known issues, `withKnownIssue`) + 83 XCTest passed in 10 suites; 0 failed, 0 skipped, 0 warnings. `swift build --package-path IntegrationTests --build-tests`: exit 0, 0 warnings. `swift test --package-path IntegrationTests`: 36 passed in 18 suites (665 s) + 2 passed in 2 suites (68 s); 0 failed, 0 skipped.
    - next: commit
  timestamp: 2026-09-05T18:07:27.579780+00:00
- actor: claude-code
  id: 01m1sc2rtzdywdnhx5bqp7cvvn
  text: |-
    ### commit — changed
    - evidence: 18f1f09 chore(kanban): record the fork cache-key fix and the pin bump (^rbtkvw1); local only, no push of this repository; tracked changes are `.kanban/` only
    - next: review
  timestamp: 2026-09-05T18:07:51.647137+00:00
- actor: claude-code
  id: 01m1sc4yphdhr666wmenfme144
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 18f1f09 — counts: 0 findings, 0 confirmed, 0 refuted; 4 of 4 files excluded by `.reviewignore` (`.kanban/`), which the engine reports as a clean review. The fork commit `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb` could not go through the engine: `review sha` with `cwd`, `path`, `repo`, or `workspace` set to the clone still resolves the sha against this repository (`revspec not found`). The fork change is covered by the fork's own tests (six new tests in `RevisionIdentity`; the five bundles green: 173, 640 + 996, 70, 7, 5) and by a check of the diff against the validator rule dump (`dump validators` for the fork's Swift files) before the commit: public items documented, the `"main"` literal named as `defaultRevision`, the switch exhaustive with no `default`, the three "never loads" model constructions folded into one `makeUnloadedModel` helper.
    - next: done
  timestamp: 2026-09-05T18:09:03.185051+00:00
- actor: claude-code
  id: 01m1sc53mt4d4x6bctv6vknhw6
  text: |-
    ### finish iteration 1 — done
    - implement: changed — fork: `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift`, `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift`; fork sha `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb` pushed to `stable` (`0147840..18ddcd1`, over SSH after the HTTPS keychain prompt hung); here: both `Package.resolved` files (git-ignored) and both `.build/checkouts/mlx-swift-lm` moved to that sha; tracked changes here are `.kanban/` only
    - test: green — fork 173 + (640 XCTest, 1 pre-existing env-var skip → card ^44z4s00) + 996 + 70 + 7 + 5, 0 failed; root 1235 + 83 passed, 0 failed, 0 skipped, 0 warnings; IntegrationTests build exit 0; gated 36 + 2 passed, 0 failed
    - commit: 18f1f09
    - review: clean — 0 findings on HEAD~1..HEAD (4 `.kanban/` files excluded by `.reviewignore`); the fork commit is covered by the fork's tests, the engine cannot review a foreign clone
  timestamp: 2026-09-05T18:09:08.250845+00:00
position_column: done
position_ordinal: ffffcc80
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
- [x] In the fork, two `MLXLanguageModel` values for one id at two revisions have two `modelID` values, two cache entries, and two container loads.
- [x] In the fork, `evict()` on one revision leaves the other revision cached.
- [x] In the fork, `modelExistsOnDisk()` still resolves through `configuration.name`.
- [x] Both `Package.resolved` files here pin the fork revision that carries the fix. (Fork sha `18ddcd16920237ba8dc8e3f6c68437cb1c1bf3bb`; both files are git-ignored, so the pin is local.)
- [x] `swift test` and `swift test --package-path IntegrationTests` are green here.

## Tests
- [x] Fork: new test in `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift`, placed under the `@Suite(.serialized)` parent that `ModelCacheEvictionTests` documents (the cache is one process-global `static let`): configurations `(id: "org/repo", revision: "a")` and `(id: "org/repo", revision: "b")` give two distinct `modelID` values and two `loadContainer()` calls on a stub loader; `evict()` on one leaves the other.
- [x] Fork: `swift test --filter MLXLanguageModelTests` → all pass. (Run as `swift build --build-tests` and `xcrun xctest` on the `MLXFoundationModelsTests` bundle, the procedure the fork's `CLAUDE.md` gives; `swift test` stops at the first GPU test with a metallib error.)
- [x] Here: `swift test` → all pass. `swift test --package-path IntegrationTests` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #defect