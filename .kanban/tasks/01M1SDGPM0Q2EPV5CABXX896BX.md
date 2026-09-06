---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1v8swx8yqkwjx15mkm33nrk
  text: |-
    ### research
    - Clone: scratchpad `mlx-swift-lm`, branch `stable`, at `fd8de95` (equal to `origin/stable`, clean tree after `git fetch origin`).
    - The fork `CLAUDE.md` forbids `swift test`. Procedure: `swift build --build-tests`, then `xcrun xctest .build/out/Products/Debug/<Bundle>.xctest` for each of the five bundles. `CLAUDE.md` line 70 says CI runs only `MLXLMTests`; line 74 says "No test is skipped."
    - `rg MLX_RUN_VARN_BENCHMARKS` and `rg VarianceNormalizedKVCacheBenchmark` in the fork find only the test file itself (`Tests/MLXLMTests/VarianceNormalizedKVCacheBenchmark.swift`). The same search here (root and `IntegrationTests`) finds nothing. No README, no CI workflow (`.github/workflows`: `ci-state.yml`, `integration_tests.yml`, `pull_request.yml`, `reset-ci-state.yml`), no script, and no `Package.swift` entry names the suite or the variable.
    - The doc comment of the suite tells the reader to run `MLX_RUN_VARN_BENCHMARKS=1 swift test --filter VarianceNormalizedKVCacheBenchmark`. `CLAUDE.md` forbids that command in the fork. The documented procedure cannot run.
    - The suite came into the fork with the squash merge `13ed148` from `main`. The fork did not add it and does not use it. Both tests print measurements and assert only the output shape or nothing; the doc comment says "deliberately enforce only correctness".
    - Every production symbol the suite uses stays in use without it: `attentionPartitionCount` and `compactStorageByteCount` are asserted in `Tests/MLXLMTests/KVCacheTests.swift` (lines 1969, 1990, 1991, 2019); `updateAndAttend` and the `sinkhornIterations:` initializer appear in 14 files. The deletion makes no internal symbol dead.
    - Rules read: `no-test-cheating` allows "Tests can be deleted entirely if they are no longer relevant or valid". `test-partitioning` says "An environment variable is NOT the convention" and item 4 flags "a new integration target with no CI task that runs it". CI runs only `MLXLMTests`, so outcome (a) would add a target that no CI task runs, which is itself a finding, unless CI also runs a GPU benchmark on each pull request.
    - Decision: outcome (b), delete the file. Reason: nothing references the two benchmarks, their documented procedure is forbidden, CI does not run them, no harness supplies configuration for them, and a new target with no CI task is a `test-partitioning` finding.
    - Plan: `git rm` the file, run `swift-format` (pre-commit rule), `swift build --build-tests`, run the five bundles, commit, push to `stable` over SSH, then update the two pins here.
  timestamp: 2026-09-06T11:49:04.040683+00:00
- actor: claude-code
  id: 01m1v94an595me2hgddszh80tf
  text: |-
    ### implement — changed
    - evidence: fork commit `36a0464 test(kvcache): delete the environment-variable benchmark suite VarianceNormalizedKVCacheBenchmark` on `stable` (pushed with SSH from the clone at `fd8de95`, `fd8de95..36a0464 HEAD -> stable`), 1 file — `Tests/MLXLMTests/VarianceNormalizedKVCacheBenchmark.swift`, 123 lines deleted (the whole file). Outcome (b): the suite is deleted. Reason: nothing in the fork or here names the suite or `MLX_RUN_VARN_BENCHMARKS` except the file itself; its doc comment names `swift test --filter`, which the fork `CLAUDE.md` forbids; no CI task runs it; no harness supplies configuration for it; and a new target with no CI task is a `test-partitioning` finding (item 4). Every production symbol the suite used stays in use (`attentionPartitionCount`, `compactStorageByteCount` in `KVCacheTests.swift`; `updateAndAttend` and `sinkhornIterations:` in 14 files), so the deletion makes no internal symbol dead. `swift-format format --in-place --configuration .swift-format --recursive .` changed no other file.
    - rules: `no-test-cheating` allows "Tests can be deleted entirely if they are no longer relevant or valid". `test-partitioning` says "An environment variable is NOT the convention" and flags "a new integration target with no CI task that runs it".
    - tdd: no production code changed; the test for this card is the bundle run that must report 0 skipped.
    - fork bundles at `36a0464`, each with `xcrun xctest .build/out/Products/Debug/<Bundle>.xctest` after `swift build --build-tests` (exit 0, only the known SwiftPM `missing creator for mutated node` bundle warning): MLXLMTests XCTest 639 passed, Swift Testing 994 in 76 suites passed (the two deleted tests and their suite are the only change from 996 in 77); MLXFoundationModelsTests 173 in 26 suites passed; MLXGuidedGenerationTests 70 in 14 suites passed; CXGrammarTests 7 in 5 suites passed; MLXHuggingFaceMacrosTests XCTest 5 passed. All five exit 0. No line says `skipped`, `Issue recorded`, or `known issue`.
    - pins: `swift package update mlx-swift-lm` (root) and `swift package --package-path IntegrationTests update mlx-swift-lm` both resolved `stable (36a0464)`; `.build/checkouts/mlx-swift-lm` and `IntegrationTests/.build/checkouts/mlx-swift-lm` are at `36a0464898bf2c45f58357aabd373f1cfc3ecfa0`.
    - next: `/test` here (root `swift test`, nested `swift build --package-path IntegrationTests --build-tests`).
  timestamp: 2026-09-06T11:54:45.797801+00:00
- actor: claude-code
  id: 01m1v975593a0mw7y4am097cyz
  text: |-
    ### test — green
    - evidence: fork at `36a0464`: `swift build --build-tests` exit 0; `xcrun xctest` per bundle — MLXLMTests XCTest 639 passed and Swift Testing 994 in 76 suites passed, 0 skipped; MLXFoundationModelsTests 173 in 26 suites passed; MLXGuidedGenerationTests 70 in 14 suites passed; CXGrammarTests 7 in 5 suites passed; MLXHuggingFaceMacrosTests XCTest 5 passed; all five exit 0. Here: root `swift test` exit 0 — 1236 tests in 134 suites passed with 2 known issues (`withKnownIssue` blocks at `RealModelHarness.swift:72` and `BoundedWait.swift:114`, which exist before this card) and 83 tests in 10 suites passed; `swift build --package-path IntegrationTests --build-tests` exit 0 ("Build complete! (20.43 sec)").
    - skipped: no bundle and no root run prints a skipped test. `rg MLX_RUN_VARN_BENCHMARKS` in the fork finds nothing.
    - warning: the only warning in the fork and in both trees here is the SwiftPM build-system line `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)`. It comes from the `swiftbuild` build system for the mlx-swift bundle, appears before this change, and is not a compiler warning from any file this card touched.
    - gated run: not needed; the change touches only a fork test target.
    - next: `/commit` here (`.kanban/` only; `Package.resolved` is git-ignored).
  timestamp: 2026-09-06T11:56:18.473609+00:00
position_column: doing
position_ordinal: '80'
title: 'Fork: remove the MLX_RUN_VARN_BENCHMARKS environment-variable gate in VarianceNormalizedKVCacheBenchmark'
---
## What
In the fork `swissarmyhammer/mlx-swift-lm` (branch `stable`), `Tests/MLXLMTests/VarianceNormalizedKVCacheBenchmark.swift` lines 36 and 84 return early unless the environment variable `MLX_RUN_VARN_BENCHMARKS` is `1`. The two tests then pass without a measurement. The test skill says: selection is never an environment variable. A test that returns early without an assertion is a silent pass.

Found while the card `^44z4s00` removed the skip in `Qwen35FusedGDNProjectionTests.testRealCheckpointBenchmark`.

## Acceptance Criteria
- [ ] No test reads `MLX_RUN_VARN_BENCHMARKS`.
- [ ] The two benchmarks live in a target that the default run does not see, or the tests are deleted if nothing references them.
- [ ] `MLXLMTests` reports 0 skipped tests.

## Tests
- [ ] Fork: `swift build --build-tests`, then `xcrun xctest .build/out/Products/Debug/MLXLMTests.xctest` → green, 0 skipped. #defect #model-pool