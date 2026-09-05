---
assignees:
- claude-code
position_column: todo
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