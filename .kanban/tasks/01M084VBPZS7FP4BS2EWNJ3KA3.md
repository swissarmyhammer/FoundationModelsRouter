---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m089fdxwdn8prk0syevmgk2p
  text: |-
    Research, before the edits.

    Group 2 — the load/preload count, derived from the resolve path, not from the failure. `Router.resolve` acquires the slots in the order standard, flash, embedding. Each `acquireModel` call reads `pool[key]` first and returns the pooled entry, so the loader runs one time for each DISTINCT `ResidencyKey`. The key is `(ref, role)`, and the generation role carries the context. `realProfile` gives one `context` to every slot, and `RealModels.standard` and `RealModels.flash` name the same repository, so the two generation slots build one key. The preload loop guards the same way with `preloadedKeys`. So the correct number is the count of distinct generation refs plus one embedder. The test now computes that number from `RealModels` instead of writing a literal, so it stays true if the two slots name different models again.

    Group 3 — the compaction fixture, measured with the real tokenizer. I read the gated model's own `tokenizer.json` out of the Hub cache and counted the scripted turns:

    - the 8 turns hold 7338 UTF-8 bytes; `Compactor.estimatedTokenCount` reports 1836; the real tokenizer reports 1496. The estimate counts about 1.23 tokens for each real token, because it divides bytes by a flat 4.0 and this prose runs about 4.9 bytes per token.
    - the live run measured 1633 tokens after all 8 turns. 1496 of those are the prompts, 18 are the instructions, and the remaining ~119 are the chat template and the last reply. The replies add almost nothing: `replyMaxTokens` is 64, the model spends that budget on its `<think>` block, and the retained answer is short.
    - the trigger is 1638 tokens (0.80 of 2048), so the fixture stopped 5 tokens short.

    That gives a calibrated model: measured ~= 0.815 x estimated + 137. The window is 2048 and the trigger is 1638, so the band a fixture may occupy is narrow: it must clear 1638 and it must not pass 2048, or a turn dies of overflow instead of folding.

    Also relevant: `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift` already records this model's `<think>` behaviour and the `[..., toolCalls, toolOutput, response, reasoning]` transcript shape.
  timestamp: 2026-08-17T16:39:33.564715+00:00
- actor: claude-code
  id: 01m08anmenpxa11j5e5rswy18z
  text: |-
    Implementation landed. What each of the six assertions now proves.

    1. `RecordingHandleIntegrationTests` (was `afterSync.map(\.kind).last == .response`). Property kept: `sync(session.transcript)` closed the executor-boundary gap, so the turn's final answer is on disk and nothing of the turn stands after it except the model's own reasoning. Now reads `afterSyncKinds.last(where: { $0 != .reasoning }) == .response`. A missing final answer leaves `.toolOutput` last and still fails; a `.prompt` or `.toolCalls` after the answer also fails.

    2 and 3. `IntegrationTests` load and preload counts. The literal `3` is gone. A new file-scoped `realProfileResidentContainerCount` counts the distinct generation references plus the distinct embedding reference, so the number comes from the profile. It reads 2 today and becomes 3 by itself if the two slots ever name different models again. The `realProfile` doc comment no longer claims "two distinct real generation models".

    4. `CompactionRoundTripIntegrationTests`. The fixture grew from eight turns to ten. The 0.80 trigger did not move: it is the production `TokenBudget.trigger` default and is the behaviour under test, so moving it would make the test assert something the product does not do.

    5. `RealToolTurnComparisonTests` (was `kinds.last == .response`). Same treatment as 1, plus a new check that the last `.response` comes after the last `.toolOutput` — the ordering the old `kinds.last` carried on its own, which the reasoning-tolerant form would otherwise drop.

    6. `LanguageModelSessionBackendTests` transcript counts of 4 and 2. Property kept: each turn appends exactly one `.prompt` and one `.response`. A shared `expectTranscriptHolds(_:turns:)` now counts those two kinds for the given number of turns and checks that no kind outside `{prompt, response, reasoning}` appears. The card's own measurement showed the total is not a function of the turn count (5 entries for the two turns that once gave 4), so no fixed total replaces it.

    The compaction fixture, in detail.

    The ungated `ScriptedTurnSizingTests` now works in the tokens a live run MEASURES, not in the character-ratio estimate. Three measured constants carry the conversion, each documented where it is declared: `realTokensPerEstimatedToken` 0.815 (1836 estimated against 1496 real), `liveOverheadTokens` 137 (1633 measured against 1496 real prompt tokens), and `triggerClearance` 1.10.

    Two bounds hold the fixture in a band:

    - lower: predicted measured tokens must clear the trigger by the clearance. Against the OLD eight turns this predicts 1633 — the number the live run actually measured — so the new test FAILS red on the old fixture. That is the gated failure reproduced with no GPU.
    - upper: predicted measured tokens must fit the 2048-token working context, so no scripted turn can die of overflow instead of folding. This subsumes the crossing-prefix bound it replaces, because a prefix is never larger than the whole.

    The two added turns are the same size as the existing ones. Predicted, against the ground-truth 1633 after eight turns: turn 9 measures about 1835, a fill near 0.90 and about 197 tokens past the trigger, against the 5 tokens it missed by before. If turn 9 somehow does not cross, turn 10 measures about 2019 and still fits the window.
  timestamp: 2026-08-17T17:00:25.429370+00:00
- actor: claude-code
  id: 01m08anxhcgvwtwjcbe0ydqctt
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterIntegrationTests/{CompactionRoundTripIntegrationTests,IntegrationTests,LanguageModelSessionBackendTests,RealToolTurnComparisonTests,RecordingHandleIntegrationTests}.swift. `swift build` clean. `swift build --build-tests -Xswiftc -warnings-as-errors` clean. `swift test` green: 973 tests in 91 suites, 27 in 11, 27 in 5; zero failures, one pre-existing known issue.
    - real-model proof: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter compactionRoundTrip` PASSED in 425 s, one run. That covers item 4 end to end, and its `CRIMSON-77` recall passed too. Items 1, 2, 3, 5 and 6 were NOT run against the real model; the full gated suite was not run, per instruction.
    - acceptance criteria: the first three hold. The fourth (a full gated `swift test` with no issue from the six) is not provable without the ~57-minute run, which was out of bounds for this step. The description checkboxes are left untouched on purpose: `update task` is known to flatten description newlines and drop tags on this board, and this description is the order.
    - next: /review
  timestamp: 2026-08-17T17:00:34.732417+00:00
- actor: claude-code
  id: 01m08asnwvwv0ph1p3af583vbc
  text: |-
    ### test — green
    - evidence: `swift build` clean (0 warnings from our code); `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift test` (ungated) — 973 tests in 91 suites passed with 1 known issue, 27 tests in 11 suites passed, 27 tests in 5 suites passed. 0 failures, 0 unexpected warnings, 0 unexplained skips. Gated `FM_ROUTER_INTEGRATION_TESTS=1` suites correctly skipped per instruction, not run.
    - next: none
  timestamp: 2026-08-17T17:02:37.979148+00:00
- actor: claude-code
  id: 01m08aw0txs3nyhfad5sv490yk
  text: |-
    ### commit — changed
    - evidence: f92e78e test(integration): re-baseline gated real-model assertions for Muse Glimmer (^wnj3ka3)
    - next: none
  timestamp: 2026-08-17T17:03:54.717921+00:00
- actor: claude-code
  id: 01m08b3b0py0bpjcvvv4kanmsd
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (checkpoint f92e78e) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 5 Swift test files reviewed; 4 `.kanban/` files excluded by `.reviewignore`.
    - scope: the checkpoint commit only, not the accumulated task diff.
    - next: no findings to record. Task moves to the terminal column.
  timestamp: 2026-08-17T17:07:54.518076+00:00
- actor: claude-code
  id: 01m08b3zfr0df3bjtfgpdz9m9y
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files in Tests/FoundationModelsRouterIntegrationTests/; each of the six assertions re-derived, none deleted or weakened
    - test: green — swift build clean, swift build --build-tests -Xswiftc -warnings-as-errors clean, swift test 973 + 27 + 27 tests, 0 failures, 1 pre-existing known issue
    - commit: f92e78e
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - note: the gated compactionRoundTrip test passed against the real model in 425 s. The other five items are not verified against the real model, and the full gated suite did not run.
  timestamp: 2026-08-17T17:08:15.480201+00:00
position_column: done
position_ordinal: ffb080
title: Re-baseline the gated real-model tests against Muse Glimmer — reasoning entries, one shared model in two slots, and a fixture below its trigger
---
Found by the gated real-model run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test` against `aff8b1b`, recorded on `^z6xdyqn`. Six of the ten gated integration issues come from test premises that two earlier commits made false. No production code is wrong here. The tests describe a model and a profile that no longer exist.

The two commits are `aa7f689` (the gated slots move to `mlx-community/Muse-Glimmer-30B-4bit`) and `c11fe07` (the loader declares `.reasoning`, because that model always reasons). Both are older than the `7e0c7c5..aff8b1b` batch.

## Group 1 — the transcript carries a `.reasoning` entry

A real tool-using turn produces this kind sequence, with `.reasoning` after `.response`:

```
["instructions", "prompt", "response", "reasoning", "toolCalls", "toolOutput",
 "response", "reasoning", "toolCalls", "toolOutput", "response", "reasoning"]
```

Failing assertions:

- `Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift:322` — `afterSync.map(\.kind).last == .response`. Measured `.reasoning`.
- `Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift:532` — `kinds.last == .response`. Measured `.reasoning`.
- `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift:195` — `backend.session.transcript.count == 4`. Measured `5`.
- `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift:212` — `child.session.transcript.count == 2`. Measured `3`.

Note the measurement at line 195: two turns gave 5 entries, not 6. One turn made a reasoning entry and the other did not. So a reasoning entry is not certain. Do not correct these counts by a fixed offset. Assert what the test means — that each turn adds one `.prompt` and one `.response`, and that other kinds may also appear.

The sibling test at line 117 already does this correctly. It compares the child count with the parent count at fork time, so the extra kind cannot break it.

## Group 2 — two slots name one model

- `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift:269` — `await loader.observedLoadPhases.count == 3`
- `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift:271` — `await loader.observedPreloadPhases.count == 3`

`RealModels.standard` and `RealModels.flash` are both `mlx-community/Muse-Glimmer-30B-4bit`, and `realProfile` gives one context to every slot. So both slots build the same `ResidencyKey`. In `Router.acquireModel` the `pool[key]` test comes first and returns before the loader runs. `preloadedKeys` guards preload again. The loader sees two calls, not three.

Decide between two corrections, and write the reason in the test:

- Make the counts `2`, and say that the two generation slots share one resident container.
- Or give `RealModels` two different generation models again. This also restores the slot-differentiation and co-residency checks, which now compare the model with itself.

The doc comment at `IntegrationTests.swift:24-28` still claims "two distinct real generation models". It is false. Correct it with whichever choice is made.

## Group 3 — the compaction fixture stops below its trigger

- `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift:444` — `fillBeforeCompaction >= 0.80`. Measured `0.79736328125`, short by 0.003.

The test drives 8 scripted turns and stops early when the fill crosses 0.80. All 8 ran and the fill stayed just below. The file records the same failure mode from an earlier model, where the fill "stalled at a `contextFill` of 0.41" and the turns were made longer. Make the fixture larger again, and keep the margin large enough that a small change of model behavior does not cross back.

Do not change the trigger to fit the measurement. The 0.80 trigger is the behavior under test.

## Out of scope

The empty summary at `CompactionRoundTripIntegrationTests.swift:487` is a separate defect. It has its own card.

## Acceptance Criteria

- [ ] The four transcript assertions state what they mean, and pass with or without a `.reasoning` entry
- [ ] The two loader-count assertions agree with the profile, and the profile doc comment is true
- [ ] The compaction fixture crosses 0.80 with a clear margin
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` reports no issue from any of these six assertions #test-debt #real-model