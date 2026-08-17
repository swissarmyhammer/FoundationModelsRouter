---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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