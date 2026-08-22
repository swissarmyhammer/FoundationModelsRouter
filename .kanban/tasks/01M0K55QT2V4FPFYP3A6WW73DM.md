---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0k7er37v7z8vm0b4m6rts3q
  text: |-
    ### finish batch 2026-08-21 — skipped, not started
    - The card says to measure on a quiet box first. At 17:35 local the box ran a GPU-heavy game at about 880 percent CPU (load average 17.5), the same load that inflated the 109–111 s measurements this card was filed on. Two whole-target runs under that load would repeat the distortion, not measure the test.
    - Start this card when the box is quiet: run the suite in isolation first (`swift test --package-path IntegrationTests --filter RealToolTurnComparisonTests`) to see the quiet-box number before you change anything.
  timestamp: 2026-08-21T22:35:52.807302+00:00
- actor: claude-code
  id: 01m0kntxv526efd2jw5wsht3gh
  text: |-
    ### implement — picked up 2026-08-21 21:47 local
    - Box load at start: `uptime` load averages 11.32 12.13 13.15; top process `Total War WARHAMMER III` at 1005 percent CPU, then `sah` at 118 percent. The box is not quiet. The user said to proceed under this load and to measure honestly. The user's processes stay as they are.
    - Plan: baseline in isolation, read the test, reduce cost without a weaker assertion or a larger budget, re-measure in isolation, then two whole-target runs for the run table.
  timestamp: 2026-08-22T02:47:11.973766+00:00
- actor: claude-code
  id: 01m0kpv6ra96md4dp0mytmp0qr
  text: |-
    ### implement — research and isolation measurements (box under a GPU-heavy game the whole time, load average 11 to 18)
    - Baseline in isolation (unchanged code, 30B, two loads, no ceiling, old instructions): both-surfaces 106.4 s, transcript-shape 55.8 s. Each turn took three rounds (one call a round).
    - Step 1 (30B, one load for both surfaces, `responseTokenCeiling` on each round, instructions ask for both calls in one step): both-surfaces 104.2 to 106.6 s, transcript-shape 47.1 to 50.2 s. Load 3.6 s; turns 51.2 and 49.5 s; 544 output tokens a turn at near eleven tokens a second; both calls in one round. The round count was not the cost. The `<think>` block is: tool calls plus answer are under 60 of the 544 tokens. No Router-side change shortens it and thinking stays on, so the 30B cannot reach half the budget.
    - Step 2 (the plan permits a smaller model when measured): `mlx-community/Qwen3-4B-4bit`, same code. It makes the same turn: both calls in one round, the same entry kinds (`instructions, prompt, response, reasoning, toolCalls, toolOutput, toolOutput, response, reasoning`), `<think>` before the calls and before the answer, both markers in the answer, streamed ids complete. Load 1.4 s; turns 8.3 and 8.3 s; 417 output tokens a turn. both-surfaces 18.0 s, transcript-shape 8.2 s. Adopted. The suite doc carries a "What it NO LONGER proves (task ^6ww73dm)" section; the model constant carries the 30B measurement that rules it out.
    - Next: two whole-target runs for the run table (rows 6 and 7), then root `swift test` and the integration build.
  timestamp: 2026-08-22T03:04:49.674135+00:00
- actor: claude-code
  id: 01m0krhzk2ebk0nvbb5cxw9z7c
  text: |-
    ### implement — changed
    - Box load: a GPU-heavy game (Total War WARHAMMER III) at 900 to 1600 percent CPU and load average 11 to 22 for the whole session. The user said to proceed under it. No user process was touched.
    - Isolation before: both-surfaces 106.4 s, transcript-shape 55.8 s (30B, two loads, no ceiling, three rounds a turn). 30B with one load, the reply ceiling and one-step instructions: 104.2 to 106.6 s — two rounds a turn, 544 output tokens a turn at near eleven tokens a second; the `<think>` block is the cost and the 30B cannot reach half the budget. Qwen3-4B-4bit, same code: 18.0 s and 8.2 s, same entry kinds, both calls in one round, both markers in the answer.
    - Whole-target run 6 (`swift test --package-path IntegrationTests`, 832 s wall, 29 tests in 14 suites passed plus 2 eval tests): both-surfaces 17.4 s, transcript-shape 8.1 s. Run 7 (733 s wall, same counts): 17.0 s and 8.0 s. Both under half of the budget. Rows 6 and 7 are in the run table; the margin paragraph names the new nearest test (`resolve real profile…`, 89.8 s in run 6) and its card ^pa5q5dt, filed by this task.
    - Changes: `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift` — `realToolTurnModel` is `mlx-community/Qwen3-4B-4bit` with the 30B measurement in its doc; `loadContainer()` loads one container for each test; `respondRun(over:)`/`streamRun(over:)` pass `GatedRealModelBudget.responseTokenCeiling`; `instructions` ask for both calls in one step; the test prints load and turn durations and token usage; suite doc carries "What it NO LONGER proves (task ^6ww73dm)". `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` — runs 6 and 7 in the table and the prose. No assertion changed; the budget is unchanged.
    - Root `swift test`: 1032 tests in 98 suites passed (2 known issues, pre-existing) and 83 tests in 10 suites passed. `swift build --build-tests --package-path IntegrationTests` builds.
    - All four acceptance boxes ticked. Left in `doing` for review.

    step: implement
    outcome: changed
    evidence: 2 files — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift; whole-target runs 6 and 7: both-surfaces 17.4 s and 17.0 s (was 109.4 and 110.7); root swift test 1032/98 and 83/10 passed; new card ^pa5q5dt
    task: ^6ww73dm
  timestamp: 2026-08-22T03:34:44.578394+00:00
- actor: claude-code
  id: 01m0krwzq50x22hn727yxda4j2
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 2858f37); counts findings 0, confirmed 0, refuted 0, attempted 7, failed 0; 2 files reviewed (RealToolTurnComparisonTests.swift, Support/GatedSuiteSerialGate.swift), 6 `.kanban/` files skipped by `.reviewignore`
    - next: none; task moved to done
  timestamp: 2026-08-22T03:40:45.157973+00:00
- actor: claude-code
  id: 01m0krxkaj0a363076mk39dkfz
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — one container load per test, round ceiling, one-step instructions, Qwen3-4B-4bit (measured: same turn shape, both markers delivered); the 30B stayed at 104–106 s because its <think> block is ~490 of 544 tokens a turn; whole-target runs 6 and 7: 17.4 s and 17.0 s (was 109.4 / 110.7), all green, box under a GPU-heavy game (load 11–22); ^pa5q5dt filed for the next-dearest test (resolve real profile…, 89.8 s)
    - test: green — root swift test 1032 + 83 passed; swift build --build-tests --package-path IntegrationTests complete
    - commit: 2858f37
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-22T03:41:05.234709+00:00
position_column: done
position_ordinal: ffec80
title: RealToolTurnComparisonTests both-surfaces test measures 109 to 111 seconds, 92 percent of the two-minute budget
---
Filed by task ^bpwfbyz, which converted the two tests that ran nearest the budget on 2026-08-20. The two whole-target runs of 2026-08-21 (`swift test --package-path IntegrationTests`, every model in the Hugging Face cache, runs 4 and 5 in the table in the doc comment of `integrationTestBudgetMinutes`) measured `RealToolTurnComparisonTests/realTurnDeliversToolDataOnBothSurfaces` at 109.4 and 110.7 seconds. That is 92 percent of `integrationTestBudgetMinutes` and the dearest test of the target now. The three runs of 2026-08-20 measured it at 86.7, 85.3 and 85.8 seconds.

The test already pins `.greedy`. It loads `RealModels.standard` (the 30B) twice and drives two multi-round tool turns, one through `respond(to:)` and one through `streamEvents(to:)`. The 30B decodes near ten tokens a second on the measuring box, and writes a `<think>` block before each round.

Note from ^bpwfbyz: the box ran a GPU-heavy game during both runs of 2026-08-21, so some of the growth from 86 to 110 seconds is the box. Measure on a quiet box first.

## Acceptance Criteria

- [x] `realTurnDeliversToolDataOnBothSurfaces` measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [x] No assertion is weakened and the budget is not raised
- [x] The suite doc states what the conversion no longer proves, as `SessionTreeRestorationIntegrationTests` does
- [x] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt