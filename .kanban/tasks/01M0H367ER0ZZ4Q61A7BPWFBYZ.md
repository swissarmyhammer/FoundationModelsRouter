---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Two integration tests fit the two-minute budget by under 20 percent, and the 30B's sampling decides which run
---
Filed by task ^k0d30s4, which gave every test of `FoundationModelsRouterIntegrationTests` a wall-clock budget of two minutes and stated that budget as each suite's `.timeLimit`.

## The measurement

Three whole runs on one Apple silicon box on 2026-08-20, every model already in the Hugging Face cache. Run 3 is the shipped command, `swift test --package-path IntegrationTests --skip CompactionEvalFullDataset`. The full table is in the doc comment of `integrationTestBudgetMinutes`, in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift`.

| test | run 1 | run 2 | run 3 | dearest share of the budget |
|---|---|---|---|---|
| `SessionTreeRestorationIntegrationTests/restoresWholeTreeAcrossSimulatedProcessBoundary` | 94.1 s | 114.1 s | 116.4 s | 97 percent |
| `RecordingHandleIntegrationTests/toolUsingTurnRoundTripsToDisk` | 16.7 s | 40.9 s | 101.5 s | 85 percent |
| `RealToolTurnComparisonTests/realTurnDeliversToolDataOnBothSurfaces` | 86.7 s | 85.3 s | 85.8 s | 72 percent |
| `LanguageModelSessionBackendIntegrationTests/secondRespondSeesPriorTurn` | 40.3 s | 48.3 s | 58.6 s | 49 percent |

Every one of them fits every run, so task ^k0d30s4's first acceptance criterion holds as measured. The dearest fits by 3.6 seconds.

## Why the numbers move so much

These suites load `RealModels.standard` (`Muse-Glimmer-30B-4bit`) and take the PROVIDER DEFAULT sampling: temperature 0.6 from MLX's clock-seeded process-global PRNG. The 30B always writes a `<think>` block before its answer, and that block is a different length on every run of identical code. Two examples with no code change between runs:

- `toolUsingTurnRoundTripsToDisk` measured 16.7 s and then 101.5 s. That is six times.
- `makeForkSeedsFromParentTranscript` measured 28.8 s, then 62.3 s, then 39.7 s.

So a run alone decides whether a test clears 120 seconds. When it does not clear it, the time limit cancels the test mid-generation, and a cancellation that lands on GPU work aborts the whole process on a Metal assertion rather than failing one test (fork card ^3axg80k). Every other suite's results are lost with it.

## What to build

Bring both dear tests well inside the budget, and pick the technique the way task ^k0d30s4 asks: state what each converted test no longer proves.

`restoresWholeTreeAcrossSimulatedProcessBoundary` drives five real turns and two model loads. Three of the five say `"Say hi in one word."` and exist only to give each fork a recorded turn, so that the sync-as-they-happen check has something to read. Each pays for a 30B `<think>` block.

`toolUsingTurnRoundTripsToDisk` drives one tool-using turn, which is several model rounds, with an UNCAPPED reply.

Two techniques are already proven in this repository, and either or both can apply:

1. **Pin the sampling.** `RealModelContainer.load(ref:)` at both sites states no `samplingMode`, so each takes the temperature-0.6 default. `CompactionRoundTripIntegrationTests`, `CompactionSmokeIntegrationTests` and both gated eval runners pin `.greedy`, and each states the same measured reason: argmax decoding consumes no randomness, so a red run can be attributed to the change under test. This removes the spread. It does not by itself make a test faster.
2. **A small model.** Task ^k0d30s4 moved `CompactionRoundTripIntegrationTests` from the 30B to `mlx-community/Qwen2.5-3B-Instruct-4bit` and it fell from 541.6 s to 17.3 s, with its fact-recall assertion still green.

Note the risk before choosing 2 for either file. `SessionTreeRestorationIntegrationTests`'s SECOND test asserts that a restored session really calls the echo tool, and `RecordingHandleIntegrationTests` asserts an exact on-disk kind sequence that holds `.toolCalls` and `.toolOutput`. Both need dependable tool calling from whatever subject replaces the 30B. Measure it, do not assume it.

## Acceptance Criteria

- [ ] `restoresWholeTreeAcrossSimulatedProcessBoundary` measures under half of `integrationTestBudgetMinutes` across two runs of the whole target
- [ ] `toolUsingTurnRoundTripsToDisk` measures under half of `integrationTestBudgetMinutes` across the same two runs
- [ ] The sampling each converted suite decodes with is stated, not inherited from the provider default
- [ ] Every test of both suites stays green, the two tool-calling assertions included
- [ ] Each suite doc states what its conversion no longer proves, as `CompactionRoundTripIntegrationTests` does
- [ ] The run table in `integrationTestBudgetMinutes` records the new measurements
#test-debt #real-model #integration