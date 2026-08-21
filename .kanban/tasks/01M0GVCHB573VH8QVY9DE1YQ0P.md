---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0hcdvx837c6hyp4acjny2nr
  text: |-
    Research done. The cause is found by reading, and it is not a change in this repository.

    1. `plan.md` says this test is expected to fail because the pinned fork has no prompt cache. That text is STALE. The `IntegrationTests` package pins `swissarmyhammer/mlx-swift-lm` branch `stable` at `ba8ff43b`, and that revision DOES carry `Libraries/MLXFoundationModels/ExecutorPromptCache.swift` (added by fork commit `08a120e`, "feat(foundation-models): reuse the prompt cache across turns"). `MLXLanguageModel.swift` there reports `cachedTokenCount: promptCache.reusedTokenCount`, not a hardcoded `0`. (The ROOT package pins an older revision, `acc9205`, which does not have the file. The two packages pin different revisions of the same branch.)

    2. The prompt cache refuses the input the standard model gives it. `ExecutorPromptCachePlan.make` starts with:
       `guard input.image == nil, input.video == nil, input.audio == nil, input.text.mask == nil, input.text.tokens.ndim == 1 else { return nil }`

    3. `RealModels.standard` is `mlx-community/Muse-Glimmer-30B-4bit`. Its `config.json` gives `model_type: muse_glimmer` and its `processor_config.json` gives `processor_class: MuseGlimmerProcessor`, so the model loads through `VLMModelFactory` and renders every prompt with `MuseGlimmerProcessor.prepare(input:)`. The text-only branch of that function is:
       `let promptArray = MLXArray(promptTokens).expandedDimensions(axis: 0)` -> `ndim == 2`
       `let mask = ones(like: promptArray).asType(.int8)` -> `mask != nil`
       `return LMInput(text: .init(tokens: promptArray, mask: mask))`

    So every text-only Muse Glimmer prompt fails the guard on two counts at once. `make` returns nil, the pass builds a fresh cache, `reusedTokenCount` stays 0, and the executor stamps `cachedTokenCount: 0`. The cache is genuinely NOT reused, and the count is genuinely 0. The two candidates the card names are one and the same here: no plan means no reuse AND no report.

    Note on the sibling test: `secondTurnTendsToBeFasterThanFirst` asserts nothing at all. It only prints a ratio. Its "pass" is therefore no evidence that the cache works.

    The correction belongs in the vendored fork, not here: `ExecutorPromptCachePlan.make` must accept a text-only input that a VLM processor batched to rank 2 with an all-ones mask. This repository cannot change how `MuseGlimmerProcessor` renders a prompt, and `muse_glimmer` is registered only in `VLMModelFactory`.
  timestamp: 2026-08-21T05:24:17.960555+00:00
- actor: claude-code
  id: 01m0hd1km39z10rqs549q8q4fx
  text: |-
    Measured, 2026-08-21. One foreground run:

    `swift test --package-path IntegrationTests --filter 'LanguageModelSessionBackendIntegrationTests'`
    - 11 tests in 1 suite, failed after 298.8 s (wall clock of the whole call: 303.9 s). 2 issues, both in `secondTurnReusesFirstTurnsKVCache`.
    - Dearest test 44.7 s, against the 120 s budget. No test came near its limit, thus no Metal abort.
    - `turn2Usage.input.cachedTokenCount -> 0`; turn 1 processed 154 tokens; tolerance 38.
    - `[secondTurnTendsToBeFasterThanFirst] turn1=7.404778003692627s turn2=2.520411968231201s ratio=0.3403764389660727`. Turn 1 also holds the first-generation warm-up of the process, so this ratio does not show cache reuse. That test asserts nothing at all; it only prints.
    - `[recordedTokenUsageMatchesLiveBackendDelta] tokensIn=62 tokensOut=130` — the usage channel itself works, thus the loss is in the cache plan, not in the usage stamp.

    Verification of this repository, with NO file changed here:
    - `swift build --build-tests -Xswiftc -warnings-as-errors` clean in the root package (12.88 s) and in `IntegrationTests` (8.46 s).
    - `swift test` green: 1025 tests in 96 suites, plus 77 tests in 9 suites.

    Where the number is lost, stated plainly: `ExecutorPromptCachePlan.make` gives nil for a text-only input whose tokens have `ndim == 2` or whose mask is not nil, and `MuseGlimmerProcessor.prepare(input:)` gives exactly such an input. The executor then runs `generateProtocolTokensTask(input: plan?.input ?? input, cache: plan?.caches, ...)` with `cache: nil`, so the turn processes the full prompt again AND reports 0.

    The correction is one guard in the vendored fork. Filed on the fork's own board at `../mlx-swift-lm` as `^7fy0d2z` — "The executor prompt cache never engages for a VLM-processor model: a batched, masked text-only input fails the plan guard". Nothing in this repository can correct it: this repository cannot change how a VLM processor renders a prompt, and `muse_glimmer` is registered only in `VLMModelFactory`.

    Two things this card must NOT do, and did not do: it did not weaken the assertion, and it did not change `RealModels.standard` to dodge the guard. Which model each slot names is a separate decision.

    New card filed on this board: `^rzr6ez5` — `plan.md` and the comment inside `secondTurnReusesFirstTurnsKVCache` both state a stale reason ("the fork has no prompt cache", "the fix has not landed"), which the pinned revision refutes. It also records that the root package resolves the fork's `stable` branch to `acc9205` while `IntegrationTests` resolves it to `ba8ff43b`.
  timestamp: 2026-08-21T05:35:04.835545+00:00
- actor: claude-code
  id: 01m0hd2p2t0mnhsw14ca1qfnjj
  text: |-
    ### implement — stuck
    - evidence: cause proved by reading and by measurement. `ExecutorPromptCachePlan.make` in the vendored fork refuses a text-only input whose tokens have `ndim == 2` or whose mask is not nil; `MuseGlimmerProcessor.prepare(input:)` gives exactly that for `RealModels.standard`. The plan is nil, so the executor generates with `cache: nil` — no reuse — and stamps `cachedTokenCount: 0` — no report. No source file changed in this repository. Runs: `swift test --package-path IntegrationTests --filter 'LanguageModelSessionBackendIntegrationTests'` — 11 tests in 1 suite, 2 issues, 298.8 s (303.9 s wall clock), dearest test 44.7 s of the 120 s budget; `swift test` (root) — 1025 tests in 96 suites plus 77 tests in 9 suites, passed; `swift build --build-tests -Xswiftc -warnings-as-errors` clean in both packages.
    - next: the correction belongs to the fork. Filed as ^7fy0d2z on the board at `../mlx-swift-lm`. This card waits for that fix and for the pin to move. Card ^rzr6ez5 on this board corrects the stale reason in `plan.md` and in the test's own comment.
  timestamp: 2026-08-21T05:35:40.122104+00:00
- actor: claude-code
  id: 01m0hd4558bxagbeysnx9yxj15
  text: |-
    ### finish iteration — stuck, and the correction is in the fork
    - implement: stuck — the cause is proved and it is one cause, not two: the fork's `ExecutorPromptCachePlan.make` refuses a text-only input that `MuseGlimmerProcessor` batched to rank 2 with an all-ones mask, so the turn generates with `cache: nil` (no reuse) AND stamps `cachedTokenCount: 0` (no report)
    - test: red, as expected — `swift test --package-path IntegrationTests --filter LanguageModelSessionBackendIntegrationTests` gives 11 tests in 1 suite with the 2 known issues, 298.8 s; root swift test 1025 in 96 suites plus 77 in 9 suites; both packages build with -warnings-as-errors
    - commit: board state only
    - No source file in this repository changed. The assertion was not weakened and the standard model was not swapped to get past the guard.

    The correction belongs to the vendored fork, so it is card ^7fy0d2z on the `../mlx-swift-lm` board. This card stays open until that lands. Card ^rzr6ez5 holds the stale `plan.md` text that says the pinned fork has no prompt cache.
  timestamp: 2026-08-21T05:36:28.328781+00:00
position_column: doing
position_ordinal: '80'
title: 'The KV cache reuse integration test is red: turn 2 reports a cachedTokenCount of zero'
---
The non-gated integration run is red on a test that has nothing to do with compaction. Measured on 2026-08-20 with `swift test --package-path IntegrationTests`, skipping the three compaction eval tiers:

```
✘ Test "turn 2's usage.input.cachedTokenCount is positive and approximates
   everything turn 1 processed — the KV cache is reused, not recomputed"
   LanguageModelSessionBackendTests.swift:569  Expectation failed: turn2Usage.input.cachedTokenCount > 0
   LanguageModelSessionBackendTests.swift:580  Expectation failed: abs(turn2Usage.input.cachedTokenCount - turn1ProcessedTokenCount) <= tolerance
✘ Suite "Gated real-model coverage: MLXFoundationModelsSessionBackend (milestone 7)"
   failed after 307.5 s with 2 issues
Test run with 29 tests in 14 suites failed after 1361.8 s with 2 issues
```

Task ^m03heaa found this while it ran the non-gated integration suite for its own work. The failing test is in `MLXFoundationModelsSessionBackend`, and ^m03heaa changed no file that reaches it, so the failure is not that card's.

The first assertion is the informative one: `turn2Usage.input.cachedTokenCount` is zero, so the second turn reports that it reused NO tokens of the first turn's prompt. Either the backend no longer reuses the KV cache across turns of one session, or the usage stamp no longer carries the count. The two have very different costs, so find out which one it is before you change anything.

## What to build

- Find whether the cache is really not reused, or only not reported. Read what the second turn costs in wall clock beside what the first turn costs: a turn that truly recomputes the whole prompt is much dearer than one that reuses it.
- If the reuse is gone, correct the backend.
- If only the stamp is gone, correct the stamp.
- Do not lower the tolerance and do not weaken the assertion to make it pass. A count of zero is not a tolerance problem.

## Acceptance Criteria

- [x] The cause is stated: no reuse, or no report
- [ ] `swift test --package-path IntegrationTests` is green on this suite
- [ ] The assertion still requires a positive `cachedTokenCount`, and still compares it against what turn 1 processed

## The cause, proved 2026-08-21

BOTH, from one cause, and the cause is in the vendored fork, not here.

`ExecutorPromptCachePlan.make` (`Libraries/MLXFoundationModels/ExecutorPromptCache.swift`) refuses any input whose tokens have `ndim != 1` or whose mask is not nil. `RealModels.standard` is `mlx-community/Muse-Glimmer-30B-4bit`, whose `processor_class` is `MuseGlimmerProcessor`; its text-only branch gives `MLXArray(promptTokens).expandedDimensions(axis: 0)` with an all-ones mask, thus rank 2 and a mask. `make` gives nil, the executor generates with `cache: nil`, and the slot reports `reusedTokenCount` of 0. The cache is not reused AND the count is 0.

`plan.md` and the comment inside the test both state a stale reason — that the fork carries no prompt cache. The pinned revision `ba8ff43b` DOES carry it. Card ^rzr6ez5 corrects those two texts.

## Blocked

The correction is one guard in the vendored `mlx-swift-lm` fork. It is filed on that fork's own board as ^7fy0d2z. This card cannot go green until that lands and the pin moves. The assertion stays as it is; it is the acceptance test for ^7fy0d2z. #integration #real-model