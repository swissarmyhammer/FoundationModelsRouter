---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0k0at6jr8ecxck7wzghhfrv
  text: |-
    Research, before the first edit.

    - `MLXFoundationModelsContainer.samplingMode` is read by `MLXFoundationModelsSessionBackend` only. It goes into the `GenerationOptions` of each `liveSession.respond`/`streamResponse` call. So `RealModelContainer.load(ref:samplingMode:)` pins the decoding for every `RoutedSession` the profile vends. `SessionTreeRestorationIntegrationTests` drives `RoutedSession`s, so the pin at its four load sites takes effect.
    - `RecordingHandleIntegrationTests` drives a raw `LanguageModelSession(model: handle, ...)`. `RoutedModel.makeLanguageModel()` wraps `container.languageModel` directly, and `RecordingLanguageModel` is a passthrough. No code reads the container's mode on that path. The pin for that suite must ride on the `GenerationOptions` the turn passes to `session.respond(to:options:)`, which is also the only place a reply ceiling can go. `PropagationProbeIntegrationTests` already passes `GenerationOptions(maximumResponseTokens: GatedRealModelBudget.responseTokenCeiling)` on a raw session, so there is precedent.
    - `RealToolTurnComparisonTests` already pins `.greedy` on the 30B with real tool calling and measured 86.7, 85.3, 85.8 seconds in the three runs. Greedy does not break the 30B's tool calling. Its doc also records that greedy does not make a tool turn repeat across runs: 11, 3, 2 and 1 tool rounds on one surface over four runs, because the tool-call ids in the transcript differ between runs.
    - `GatedRealModelBudget.responseTokenCeiling` is 4096. Its doc records that a 512 ceiling leaves the tool turn of the probe suite with an empty response. The 30B's `<think>` block takes the ceiling before the answer.
    - Both models are in the Hugging Face cache: `Muse-Glimmer-30B-4bit` (18 GB) and `Qwen2.5-3B-Instruct-4bit` (1.6 GB). The box has 512 GB.

    Plan: pin `.greedy` in both suites first, measure each in isolation with temporary per-turn prints of seconds and `tokensOut`, then pick the filler-turn ceiling from the measured `<think>` length, remove the prints, and measure again.
  timestamp: 2026-08-21T20:31:23.858840+00:00
- actor: claude-code
  id: 01m0k10s7twhx0kt8pmaz9eq4j
  text: |-
    Isolated measurements, 2026-08-21, with temporary per-turn prints (seconds and the response event's `tokensOut`).

    Round A: `.greedy` pinned, no other change.

    `SessionTreeRestorationIntegrationTests`, fork-tree test: 112.4 s. load1 3.7 s; root turn 16.0 s for 117 tokens; forkA filler 37.0 s for 275 tokens; forkB filler 19.2 s for 208; grandfork filler 18.4 s for 196; load2 3.5 s; restore 0.01 s; recall turn 14.2 s for 151 tokens. Tool-calling test: 51.6 s. load 3.5 s; root filler 25.7 s for 196 tokens; load 3.5 s; tool turn 18.5 s for 178 tokens, two model rounds, kinds `toolCalls,toolOutput,response,reasoning` present.

    `RecordingHandleIntegrationTests`: 32.5 s. load 3.4 s; the tool turn 28.9 s, two rounds, kinds `session,instructions,prompt,response,reasoning,toolCalls,toolOutput` before sync. Green. Greedy and the shared 4096 ceiling on the turn's `GenerationOptions` are enough for this suite. No model change needed there.

    Facts: a model load is 3.5 s, not the cost. The 30B decodes near 10 tokens a second on this box, and writes a `<think>` block of 196 to 275 tokens before it answers "Say hi in one word.". The three filler turns were 74 s of 112 s.

    Round B: filler turns capped at 32 tokens (cut inside the `<think>` block).

    Fork-tree test: 65.0 s. Fillers 5.1, 4.9, 4.7 s (32 tokens each, kinds `prompt,response,reasoning` still recorded). BUT the recall turn on the restored grandfork grew from 14.2 s/151 tokens to 26.4 s/267 tokens, because the restored transcript now holds two cut `<think>` blocks. Still recalled 42. Tool-calling test: the root's filler took 5.5 s, then the tool turn on the restored root ran past the two-minute limit (wallClockSeconds=120.4, no pass line). The cut filler in the root's transcript changed the next turn's behavior. A filler cut inside the `<think>` block is a dead end: it destabilizes every later turn over that transcript.

    Arithmetic for the 30B: root 16 s + recall 14 s + two loads 7 s = 37 s fixed. Even a filler with the shortest complete reply this model writes (about 100 to 120 tokens, 10 to 12 s) puts three fillers at 30 to 36 s, total 67 to 73 s. The fork-tree test cannot get under 60 s on the 30B on this box without cutting a filler mid-think, and that is measured harmful.

    Next: try `mlx-community/Qwen2.5-3B-Instruct-4bit` for `SessionTreeRestorationIntegrationTests` (technique 2), and measure its tool calling in the second test. The filler cap is removed; the fillers go back to the shared ceiling.
  timestamp: 2026-08-21T20:43:23.770309+00:00
- actor: claude-code
  id: 01m0k5ah1g83qwwpakf7cp99se
  text: |-
    Implementation landed.

    What changed:
    - `SessionTreeRestorationIntegrationTests`: two model constants now. `sessionTreeForkTreeModel` = `mlx-community/Qwen2.5-3B-Instruct-4bit` drives the fork-tree test; `sessionTreeToolCallingModel` = `RealModels.standard` (the 30B) drives the tool-calling test, because the 3B garbled its one tool call (`<tool_call>{{"name": "echo", ...}}}`, `RejectedToolCallError ... incompleteOutput`). `samplingMode = .greedy` is pinned at all four `RealModelContainer.load` sites. `makeProfile` takes `model:`. The suite doc has a "What it NO LONGER proves" section with every measurement. No assertion changed.
    - `RecordingHandleIntegrationTests`: stays on the 30B. A `turnOptions` constant states `.greedy` and `GatedRealModelBudget.responseTokenCeiling` on the turn's `GenerationOptions`, with the doc stating why the pin rides on the turn and not on the load (the raw `LanguageModelSession` over the handle reads no container mode). Suite doc has the same section. `import FoundationModelsRouterTestSupport` added for the ceiling.
    - `GatedSuiteSerialGate.swift`: the run table carries runs 4 and 5 (the two whole-target runs of 2026-08-21) and the margin prose names the new nearest test.
    - `RealToolTurnComparisonTests` doc: the stale "two suites run nearer the budget" sentence replaced with the new numbers and a pointer to ^6ww73dm.
    - Ten other suite docs: "three-run table" -> "run table", because the table now holds five runs.
    - The temporary per-turn `[probe]` prints used for the isolated measurements were removed before the whole-target runs.

    Whole-target runs (`swift test --package-path IntegrationTests`, one after the other), both green, 29 tests in 14 suites plus the 2 eval suites:
    - run 4: fork-tree 3.1 s, tool-calling test 49.6 s, handle 55.4 s
    - run 5: fork-tree 3.1 s, tool-calling test 47.9 s, handle 44.8 s
    Both dear tests under 60 s in both runs. Note: the box ran a GPU-heavy process (Total War: WARHAMMER III, 985 percent CPU, 9 hours) for the whole of both runs, so every 30B row is slower than on 2026-08-20; I did not stop the user's process. `RealToolTurnComparisonTests` both-surfaces test measured 109.4 and 110.7 s (92 percent) and is now the nearest to the limit; filed ^6ww73dm for it.

    Root `swift test`: 1032 tests in 98 suites passed (2 known issues, pre-existing `withKnownIssue`), plus 80 tests in 10 suites passed. `swift build --package-path IntegrationTests --build-tests` clean after the final doc edits.

    Dead ends recorded above: a filler turn cut at 32 tokens inside the `<think>` block (65 s, and it pushed the tool-calling test past the limit); the 3B for the tool-calling test (garbled tool call).
  timestamp: 2026-08-21T21:58:37.360488+00:00
- actor: claude-code
  id: 01m0k5as54c16ff4af6vxsr3fe
  text: |-
    ### implement — changed
    - evidence: 14 files changed under IntegrationTests/Tests/FoundationModelsRouterIntegrationTests — SessionTreeRestorationIntegrationTests.swift, RecordingHandleIntegrationTests.swift, Support/GatedSuiteSerialGate.swift, RealToolTurnComparisonTests.swift, and ten doc-only "run table" edits (AutoCompactionTrigger, CancelledGenerationTeardown, CompactionSmoke, CompactionSpike, IntegrationTests, LanguageModelSessionBackendTests, MetalLibraryBootstrap, PropagationProbe, RecordedTranscriptCompaction, TranscriptReconstruction). Whole-target run 4: fork-tree 3.1 s, handle 55.4 s; run 5: fork-tree 3.1 s, handle 44.8 s; both runs all green (29 tests in 14 suites + 2 eval suites). Sampling: `.greedy` pinned on both converted suites (SessionTree at the four load sites; RecordingHandle on the turn's `GenerationOptions`, plus the 4096 ceiling). Models: fork-tree test on Qwen2.5-3B-Instruct-4bit, tool-calling test and RecordingHandle on RealModels.standard (30B). Root `swift test`: 1032 tests in 98 suites + 80 tests in 10 suites passed. New card ^6ww73dm filed for RealToolTurnComparisonTests at 109–111 s.
    - next: `/review`
  timestamp: 2026-08-21T21:58:45.668746+00:00
- actor: claude-code
  id: 01m0k5hy5wd7dgkhk9q0p335f2
  text: |-
    ### commit — changed
    - evidence: 2e07e98 test(integration): pin greedy decoding and shrink the two dearest gated tests inside half the budget (^bpwfbyz) — 18 files changed, 361 insertions(+), 124 deletions(-)
    - next: /review
  timestamp: 2026-08-21T22:02:40.188151+00:00
- actor: claude-code
  id: 01m0k5pjm2ytv160p7n3pefqmp
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 2e07e98), 14 files reviewed, counts findings 0 / confirmed 0 / refuted 0; 4 `.kanban/` files skipped by `.reviewignore`
    - next: none, task moved to done
  timestamp: 2026-08-21T22:05:12.194853+00:00
- actor: claude-code
  id: 01m0k5q7mpty6h49pys2c5a5ar
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 14 files under IntegrationTests/Tests/FoundationModelsRouterIntegrationTests; greedy pins; fork-tree test on Qwen2.5-3B, tool-calling test and RecordingHandle on the 30B with the response ceiling; two whole-target runs green: fork-tree 3.1 / 3.1 s, handle 55.4 / 44.8 s, tool-calling 49.6 / 47.9 s (box under GPU load from a game); ^6ww73dm filed for RealToolTurnComparisonTests at 109–111 s
    - test: green — root swift test 1032 + 80 passed; swift build --build-tests --package-path IntegrationTests complete
    - commit: 2e07e98
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-21T22:05:33.718256+00:00
position_column: done
position_ordinal: ffe980
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

- [x] `restoresWholeTreeAcrossSimulatedProcessBoundary` measures under half of `integrationTestBudgetMinutes` across two runs of the whole target
- [x] `toolUsingTurnRoundTripsToDisk` measures under half of `integrationTestBudgetMinutes` across the same two runs
- [x] The sampling each converted suite decodes with is stated, not inherited from the provider default
- [x] Every test of both suites stays green, the two tool-calling assertions included
- [x] Each suite doc states what its conversion no longer proves, as `CompactionRoundTripIntegrationTests` does
- [x] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt