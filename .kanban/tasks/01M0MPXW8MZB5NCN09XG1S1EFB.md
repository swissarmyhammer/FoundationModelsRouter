---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0mqhe5v68489kkbkk5nrd8f
  text: |-
    ### Which of the two pins this suite needs — answered before the work starts

    The FoundationModelsMultitool session asked the correct question of this card: not "does it fit the budget" but "why do two runs of one test differ by 2.6 times". A read of the suite answers it, and the answer is cheap.

    **This suite drives `MLXFoundationModelsSessionBackend`, so the load-time pin DOES apply here.** `makeForkSeedsFromParentTranscript()` at `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift:86` calls `container.makeSession(instructions:)` and requires the result as `MLXFoundationModelsSessionBackend`. That is the one type that reads the container's stored `samplingMode`. So this card is NOT the propagation probe's shape: the pin goes on `RealModelContainer.load(ref:samplingMode:)`, not in a `GenerationOptions` the turn passes.

    **Nothing pins it now.** `RealModelContainer.load(ref:samplingMode:)` in `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift:58` defaults `samplingMode` to `nil`, and its own doc says that leaves the provider default in place and the provider default samples. All eight call sites in this suite call `RealModelContainer.load(ref: sessionBackendTinyModel)` with no `samplingMode`. Each turn already states `maxTokens: GatedRealModelBudget.responseTokenCeiling`, so sampling is the only axis of this test that is not pinned.

    **The model is the 30B.** `sessionBackendTinyModel` is `RealModels.standard` (line 11). The name says tiny and the value is not; correct the name with this work.

    So the first measurement to make is one run with `samplingMode: .greedy` on the load. If the number stops moving, the spread was decode variance and the card is a budget card. If the number still moves by 2.6 times with the pin in place, the cause is not decoding, and the card becomes a determinism card that needs a transcript read — the peer's ^4qcf1v9 was exactly that: a 12-times spread that read as three machine speeds and was a live-lock of 21 rounds, in a run that still PASSED with 14.33 seconds of margin. Add the per-phase clock first, as this card already asks.

    Two call sites need thought before a suite-wide pin, because their assertions are about time and cache rather than text: `secondTurnReusesFirstTurnsKVCache()` (line 498) and `secondTurnTendsToBeFasterThanFirst()` (line 589).
  timestamp: 2026-08-22T12:36:12.603106+00:00
- actor: claude-code
  id: 01m0mv329mfaa92r806thb4m4t
  text: |-
    ### Picked up — research confirmed, plan set

    The comment on this card is correct on each fact, and a read of the suite confirms them:

    - Eight `RealModelContainer.load(ref: sessionBackendTinyModel)` call sites, none of which states a `samplingMode`. The parameter defaults to `nil`, and the default samples.
    - Each turn already states `maxTokens: GatedRealModelBudget.responseTokenCeiling` (4096).
    - `sessionBackendTinyModel` is `RealModels.standard`, the 30B `mlx-community/Muse-Glimmer-30B-4bit`. The name is wrong.
    - The test under the card drives THREE turns on one load: the parent's `Remember the number 42.`, the child's recall turn after the fork, and the parent's second turn. Three sampled `<think>` blocks are three sources of spread on one clock.

    `SessionTreeRestorationIntegrationTests` is the closest shape to copy: a suite-wide `private static let samplingMode: GenerationOptions.SamplingMode = .greedy`, one private loader that every test calls, and a `## What it NO LONGER proves` section on the suite doc. `PropagationProbeIntegrationTests` gives the shape of the per-phase clock: a suite-private `phaseLabel`, `ContinuousClock` durations, and one `defer`red print, so the split prints however the test ends.

    Plan, in this order:
    1. Rename the model constant, fold the eight loads onto one private loader, add the per-phase clock (load, each of the three turns, evict). No pin yet.
    2. Measure the test in isolation on this code. That is the baseline the decision point needs.
    3. Pin `samplingMode: .greedy` on the loader. Measure in isolation again, twice.
    4. If the number stops moving, this is a budget card: state what the pin no longer proves and record runs 12 and 13 of the whole target. If it still spreads by about 2.6 times, this becomes a determinism card and the transcript gets read.

    The two call sites the comment flags need no different treatment, and the reason is short. `secondTurnReusesFirstTurnsKVCache()` asserts on `cachedTokenCount` against turn 1's own prompt and processed counts; argmax changes WHICH tokens turn 1 writes, never whether turn 2 reuses the prefix, and both bounds are stated against turn 1's own measured counts rather than against a constant. `secondTurnTendsToBeFasterThanFirst()` asserts nothing at all — it prints a ratio — and a pinned decode makes that ratio less noisy, not more.
  timestamp: 2026-08-22T13:38:15.988119+00:00
- actor: claude-code
  id: 01m0mvm92szkmfsycrmh0sdp1d
  text: |-
    ### The decision point, answered: it is decode variance, so this is a budget card

    The per-phase clock was added first and measured before the pin, exactly as the card asks. Every number below was measured on 2026-08-22 on the same box, with the 30B already in the Hugging Face cache, one test in isolation (`swift test --package-path IntegrationTests --filter 'makeForkSeedsFromParentTranscript'`). The load average is stated with each run, and the box was quiet throughout — nothing like the 14.3 and 11.1 of runs 10 and 11.

    **Under the provider default (no pin), load average 2.26 then 2.70:**

    | run | load | parentTurn | childTurn | parentSecondTurn | evict | total |
    |---|---|---|---|---|---|---|
    | 1 | 3.39 | 23.46 | 9.44 | 2.27 | 0.08 | 38.6 |
    | 2 | 3.11 | 24.64 | 13.42 | 2.18 | 0.08 | 43.4 |

    The clock answers the question ^s49ya8p's clock answered for the propagation probe: **the load is not the cost.** It is 3.4 of 38.6 seconds, 8 percent, so a repair aimed at the load buys nothing. The three turns are the test. And the fork's own turn moved from 9.44 to 13.42 seconds — 43 percent — between two runs of identical code on a quiet box, which is the sampled decode and nothing else.

    **With `samplingMode: .greedy` pinned at load time, load average 2.17 then 3.86:**

    | run | load | parentTurn | childTurn | parentSecondTurn | evict | total |
    |---|---|---|---|---|---|---|
    | 1 | 2.93 | 27.36 | 13.157 | 2.070 | 0.080 | 45.6 |
    | 2 | 2.99 | 26.42 | 13.126 | 2.077 | 0.084 | 44.7 |

    **The number stopped moving.** The two splits agree phase by phase: the fork's own turn measured 13.157 then 13.126 seconds, 0.2 percent apart, where the unpinned pair was 43 percent apart. The total moved by 2 percent, against a factor of 2.6 between runs 10 and 11. So the cause IS decoding, this is NOT the determinism card the peer's ^4qcf1v9 turned out to be, and the card is finished as a budget card.

    One fact a reader should not miss: the pin did not make the test faster. 45.6 is above the 38.6 and 43.4 the unpinned runs measured, because the greedy `<think>` block for these prompts happens to be longer than the average sampled one. What the pin buys is the LOSS OF THE TAIL — the 76.3 of run 10 cannot happen again, because the decode length is no longer drawn. 45.6 seconds is 38 percent of `integrationTestBudgetMinutes` and well under the half the card asks for.

    The two call sites the earlier comment flagged were both taken under the suite-wide pin, and neither assertion changed:
    - `secondTurnReusesFirstTurnsKVCache()` states both of its bounds against turn 1's OWN measured counts, never against a constant, so a different turn-1 reply moves both sides together.
    - `secondTurnTendsToBeFasterThanFirst()` asserts nothing; it prints a ratio, and a pinned decode makes that ratio less noisy.

    Still to do: the whole-target runs 12 and 13, and the run table.
  timestamp: 2026-08-22T13:47:39.993519+00:00
- actor: claude-code
  id: 01m0mx6wq9gj59wfnjhpf4akk9
  text: |-
    ### Runs 12 and 13 of the whole target, both green

    `swift test --package-path IntegrationTests`, 2026-08-22, the same box.

    | | run 12 | run 13 |
    |---|---|---|
    | started | 08:47 | 08:58 |
    | load average at start | 2.33 | 7.36 |
    | load average at end | 3.10 | 9.98 |
    | integration target | 29 tests in 14 suites, 526.6 s | 29 tests in 14 suites, 605.3 s |
    | eval target | 2 tests in 2 suites, 92.6 s | 2 tests in 2 suites, 107.3 s |
    | result | passed, exit 0 | passed, exit 0 |
    | `makeFork()` | **46.9 s** | **51.8 s** |

    Acceptance criterion 1 is met: 46.9 and 51.8 seconds, both under 60, which is half of `integrationTestBudgetMinutes`. The test is 39 and 43 percent of the budget, against 64 percent in run 10.

    Run 13 measured on a busier box than run 12 — the load average climbed from 7.4 to 10.0 while it ran, where run 12 held 2.3 to 3.1 — and nearly every row of the table grew between the two for that reason.

    The clock and the token counts together say the growth is the box and not the decode. The per-phase line reads `load=3.206 parentTurn=27.633 childTurn=13.779 parentSecondTurn=2.158` in run 12 and `load=3.553 parentTurn=31.687 childTurn=14.350 parentSecondTurn=2.150` in run 13, while the suite's own two prints are **identical byte for byte in both runs**: `turn1In=49 turn1Out=76 turn2Cached=50` and `tokensIn=62 tokensOut=128`. Identical token counts with a different wall clock is exactly the signature of a machine that got busier, and it is the opposite of runs 10 and 11.

    The whole suite got cheaper with the pin beside the quieter box, not only the test on this card:

    | test | run 10 | run 11 | run 12 | run 13 |
    |---|---|---|---|---|
    | a second respond() call sees the first turn | 47.5 | 46.6 | 36.5 | 40.1 |
    | makeSession(transcript:) seeds a fresh backend | 48.7 | 48.0 | 44.6 | 45.2 |
    | turn 2's cachedTokenCount is positive | 40.3 | 46.6 | 36.5 | 42.3 |
    | each respond() leaves one prompt and one response | 26.5 | 22.6 | 18.9 | 20.0 |
    | turn 2 tends to be faster than turn 1 | 14.5 | 14.2 | 10.7 | 12.1 |

    **No test of runs 12 or 13 reaches half the budget.** The nearest is now `resolve real profile, then generate, embed, guide, fork, and record` at 48.6 and 57.0 seconds, 48 percent of the budget in run 13, so this change leaves no successor card behind it.

    Two recorded measurements in the file's doc comments describe replies the pinned code no longer writes, and both are records rather than assertions: `secondTurnReusesFirstTurnsKVCache` records `turn1In=49 turn1Out=84 turn2Cached=50` and `recordedTokenUsageMatchesLiveBackendDelta` records `tokensIn=62 tokensOut=149`. Under argmax both runs print `turn1Out=76` and `tokensOut=128`. Those two records are being corrected to what the pinned code measures.
  timestamp: 2026-08-22T14:15:18.505107+00:00
- actor: claude-code
  id: 01m0mxsd7zak0fpsk9vmwqpnj8
  text: |-
    ### implement — changed

    - evidence: 3 files — `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift`, `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`. 250 insertions, 95 deletions. `makeFork() seeds the child's transcript from the parent's` measures 46.9 s in run 12 (load average 2.33 to 3.10) and 51.8 s in run 13 (load average 7.36 to 9.98), against 76.3 and 28.9 in runs 10 and 11. Both whole-target runs passed with exit 0: 29 tests in 14 suites plus 2 tests in 2 suites. `swift test` at the root passes: 1032 tests in 98 suites and 83 tests in 10 suites, 2 pre-existing known issues, zero failures and zero warnings. Both packages build clean.
    - next: `/review`

    **Each acceptance criterion, against the diff:**

    1. **Under half the budget across two whole-target runs.** 46.9 and 51.8 seconds, both under 60. Met.
    2. **No assertion weakened, budget not raised.** `#expect` count 30 before and 30 after, `#require` 13 and 13, `@Test` 11 and 11, each verified against `git show HEAD:`. `integrationTestBudgetMinutes = 2` has no diff line.
    3. **The suite doc states what the change no longer proves.** `LanguageModelSessionBackendIntegrationTests` carries a `## What it NO LONGER proves (task ^g1s1efb)` section in the shape `IntegrationTests`, `PropagationProbeIntegrationTests` and `SessionTreeRestorationIntegrationTests` use: the per-phase split that named the cost, the two isolated pinned measurements, and two named losses — the sampled path, and that each recalled fact survives a sampled decode.
    4. **The run table records the new measurements.** The table in `integrationTestBudgetMinutes` now carries `run 12` and `run 13` columns for all 29 rows, and the prose around it states the provenance of the two runs, the load average of each, which two suites still take the provider default, and that no test of runs 12 or 13 reaches half the budget.

    **What changed, beyond the pin:**

    - `sessionBackendTinyModel` is renamed `sessionBackendModel`, as the card asks. Its doc records the old name and why it was wrong. Three stale prose references to a "tiny model" in the same file are corrected with it.
    - The eight spelled-out `RealModelContainer.load(ref:)` calls fold onto one `makeContainer()`, so the decoding cannot drift between them. One `RealModelContainer.load` call remains in the file.
    - `makeForkSeedsFromParentTranscript()` prints a five-phase clock under its own `sessionBackendPhase` tag — its own tag, so a grep for the run table's `gatedTest` lines never picks up a phase line.
    - Two recorded measurements that describe replies the pinned code no longer writes are corrected to what it does write, and each states that the old number came from a sampled run: the KV-cache comment in this suite, and the `usageTokenCounts()` doc in `LiveModelLoader.swift`. That production doc is the only file outside the integration package this change touches, and the edit is a doc comment.
  timestamp: 2026-08-22T14:25:25.247289+00:00
position_column: doing
position_ordinal: '80'
title: '`makeFork() seeds the child''s transcript from the parent''s` measured 76.3 seconds, 64 percent of the budget, and 2.6 times its sibling run'
---
Filed by task ^s49ya8p, which took `MLX path: whether the ToolContext bound around respond() arrives` under half of `integrationTestBudgetMinutes`. The two whole-target runs of 2026-08-22 after that change (runs 10 and 11 in the table in the doc comment of `integrationTestBudgetMinutes`) measured this test of `LanguageModelSessionBackendTests` at 76.3 and 28.9 seconds. The 76.3 is 64 percent of the budget, and this test is now the nearest to the limit in the target.

The 76.3 is also 2.6 times the 28.9 the very next run of the same code measured, on the same box under the same load. Runs 1 to 9 measured it at 28.8, 62.3, 39.7, 63.8, 45.6, 39.9, 30.4, 44.7 and 48.6 seconds, so the number moves by a factor of two or more with no code change to the suite.

That shape says the turn takes the provider's default sampling: the 30B writes a `<think>` block of a different length on every run. Task ^s49ya8p found the same cause under the propagation probe, and it found one thing a reader of this card needs. A sampling mode pinned at load time — `RealModelContainer.load(ref:samplingMode:)` — is stored on `MLXFoundationModelsContainer` and read only by `MLXFoundationModelsSessionBackend`. A suite that drives a raw `LanguageModelSession` does not read it, and the pin must go in the `GenerationOptions` the turn passes. Read `LanguageModelSessionBackendTests` to see which of the two it drives.

Read `IntegrationTests`, `RealToolTurnComparisonTests` and `PropagationProbeIntegrationTests` for the three shapes of the repair. Add a per-phase clock before choosing one: task ^s49ya8p's clock proved that the two model loads were 7.3 of 86.9 seconds and the turn was the rest, so a repair aimed at the loads would have bought nothing.

A test the limit cancels is worse than a plain red result. The cancellation lands mid-generation, and a cancellation on GPU work aborts the whole process on a Metal assertion (fork card ^3axg80k), which takes every other suite's results with it.

The box ran a GPU-heavy game for both runs, at load average 14.3 and 11.1, so some of the spread is the box. Measure on a quiet box first.

## Acceptance Criteria

- [x] The test measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [x] No assertion is weakened and the budget is not raised
- [x] The suite doc states what the conversion no longer proves, as `IntegrationTests`, `PropagationProbeIntegrationTests` and `SessionTreeRestorationIntegrationTests` do
- [x] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt