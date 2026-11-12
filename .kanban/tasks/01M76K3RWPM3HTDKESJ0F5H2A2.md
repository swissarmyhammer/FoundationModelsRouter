---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77p6qxr9441ryhs5eyz6vnp
  text: |-
    ### Decision — the user selected: use smaller models in the cross-router test
    - The user decided (relayed by the FoundationModelsDecision session): no revocable hold and no Extras API.
    - Reason: the pool counts the holds. `ModelHold.deinit` releases a hold, and the last release evicts the model. The handles keep the decision hold in `residencyHolds` with a weak link back to the profile. `CrossRouterPoolIntegrationTests` keeps both profiles alive on purpose, so all the models are loaded and in use. The models of `gatedRealProfile` with a decision model were too large for the memory of `mini-01`.
    - Done: `CrossRouterPoolIntegrationTests` resolves a profile of its own, `crossRouterProfile`: standard `mlx-community/Llama-3.2-1B-Instruct-4bit`, flash `mlx-community/Qwen3-1.7B-4bit`, embedding `RealModels.embedding`, decision `Mapika/decider-2b-GGUF/decider-2b-v12-Q4_K_M.gguf`, context 4096. The first test also expects the decider in the decision slot, and each count includes the decision container (4).
    - `gatedRealProfile` keeps `decision: []`. Only `IntegrationTests` uses it, on one router, with no pool shared across routers.
    - test: green — `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests`, 4 tests in 1 suite passed after 37.360 seconds, 0 warnings.
  timestamp: 2026-11-12T10:52:38.712999+00:00
position_column: done
position_ordinal: ffffffffff8880
title: A decision model of one resolve can make the trio of a later resolve on the same pool not fit
---
## What
Found in task ^epw68dv (CI run 43122216651, runner `mini-01`).

Two routers share one `ModelPool` and resolve the same profile. Router 1 loads the trio and then the default decision model `Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf` in the memory that its trio left (R4, `JointFit.resolveDecision`). Router 2 then gets the budget `hostBudget() - admission.footprint.totalBytes` (`Router.runAdmission`). That budget is 1155104301 bytes, and the flash slot of router 2 needs one more session KV of the resident `Qwen3-4B-4bit` (1207959552 bytes). Thus router 2 throws `ResolutionFailure`. With `decision: []`, router 1 leaves about 3.7 GB more free, and router 2 resolves.

Within one resolve, R4 holds: the decision pass never changes the trio. Across resolves on one pool, the decision model of one owner takes memory that the trio of a later owner needs. The prompt cache budget of router 1's own loader (`PromptCacheSizing`) also gets smaller by the bytes of the decision model.

The router cannot give that memory back now:
- `ModelPool` (FoundationModelsExtras) has no API to evict a model that a hold keeps.
- The decision hold is in `residencyHolds` of every handle of the profile, and in its `PooledDecisionModel`.

## Options (the user decides scope)
1. A revocable decision hold: a later admission can release the decision models of other owners when its trio needs the memory. The decision container of that owner then uses its flash model. This needs an Extras API and a router feature (the `RoutedDecider` model changes after the resolve; the recording of the decision model changes).
2. Keep the current behavior and document it: the decision model is a resident model of its owner, and a later resolve sees it as used memory.
3. A fit that counts decision memory as free is NOT an option: it loads over the budget.

## Acceptance Criteria
- [x] The user selects an option: smaller models in the cross-router test (no revocable hold, no Extras API).
- [x] `CrossRouterPoolIntegrationTests` resolves a profile of small models with `decider-2b` in the decision slot, and its 4 tests pass. #decision