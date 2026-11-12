---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76k2060cd0v2s3tyjp1j68p
  text: |-
    Cause, with evidence (research done):

    1. The gated real profile (`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedRealProfile.swift`) does not set `decision`. Thus it gets `ProfileDefinition.defaultDecisionCandidates` = `Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf` (`Sources/FoundationModelsRouter/Core/ProfileDefinition.swift`). The CrossRouterPool routers use the default `HuggingFaceMetadataSource`, which reads GGUF header bytes. Thus the decider is sized, it fits in the budget that the trio left (`JointFit.resolveDecision`), and `Router.acquireSlots` loads it as a fourth container.
       - CI log: router 1 opens 4 load spans; the fourth is `model.ref=Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf model.role=llm ... enter FoundationModelsExtras.model.load`. Then `firstLoadSpans.count → 4`, `gatedRealProfileResidentContainerCount → 3` (`:225`). `:226` is not evaluated after that.
       - `:324`/`:325` (PooledModel test): `fixture.router.loadSpans.count → 3` (standard, embedding, decider; expected 2) and `fixture.pool.residentModelCount → 4` (expected 3). Same cause: one more container.

    2. The `ResolutionFailure` at `:218` and `:251` comes from router 2, not router 1. The CI log prints the slots of the failure:
       - `embedding (remaining 1155104301 bytes, context 8192 tokens): chose ... — 0 bytes`
       - `standard (remaining 1155104301 bytes): chose mlx-community/Muse-Glimmer-30B-mxfp4 — 109051904 bytes` (the session KV of a resident model)
       - `flash (remaining 1046052397 bytes): no viable candidate — mlx-community/Qwen3-4B-4bit — 1207959552 bytes: too large` (the session KV of a resident model: 147456 bytes/token x 8192)
       The decision slot is not in the failure. The trio of router 2 fails before the decision pass runs, thus the decision slot of router 2 did not throw and did not block. `Router.runAdmission` gives router 2 the budget `hostBudget() - admission.footprint.totalBytes`. On the CI runner `mini-01` that is 1.155 GB, because the pool keeps the trio AND the decider of router 1. The decider took about 3.7 GB (Q4_K_M weights plus its KV at 8192) of the memory that router 1's trio left. With `decision: []`, that memory stays free, and router 2 needs only 109 MB + 1.21 GB. The local box (128 GB) has a much larger budget, thus the `ResolutionFailure` does not occur locally; only the count failures occur.

    3. Is it a router bug? Router 1 applied the R4 contract (plan section 7, R4; task ^jmc5vmj): its decision pass used only the memory left after its own trio, and its trio is the same as with `decision: []`. For router 2, the decider is a resident model of another owner, the same as any other resident model; the budget is real memory, and a trio that needs more than the free memory must fail, not load over the budget. The router has no way to give that memory back: `ModelPool` (Extras) has no API to evict a model that a hold keeps, and the decider hold is in every handle of router 1's profile (`residencyHolds`) and in its `PooledDecisionModel`. The only fixes for the cross-resolve case are (a) a revocable decision hold (an Extras API change and a new router feature), or (b) a fit that counts decider memory as free (it loads over the budget, which is a bug of its own). Both are a scope decision for the user. I record this gap as a new task and do not change the router.

    4. The milestone 7 suite (`IntegrationTests.swift`) also counts `gatedRealProfileResidentContainerCount`, and it passed in CI only by accident: its `PhaseRecordingSource` does not implement `fetchFileBytes`, thus the default `MetadataSource.fetchFileBytes` throws, the GGUF decider is `metadataUnavailable`, and the slot uses the flash fallback. In the CI log that test loads only Muse-Glimmer, Qwen3-4B and the embedder.

    Fix (the card's first option): give `gatedRealProfile` `decision: []`. These suites check the trio, not the decision slot (`DecisionSlotIntegrationTests` covers the decision slot with its own profile). The decision slot then uses the flash key, costs 0 bytes and opens no load span (`Router.acquire`, `isHeldByThisResolve`), so the count of resident containers stays 3 on every runner and with every metadata source.
  timestamp: 2026-11-12T00:38:23.168123+00:00
- actor: claude-code
  id: 01m76kc7ggzf2tc7zk24746wfm
  text: |-
    Implementation landed.
    - Change: `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedRealProfile.swift`: `gatedRealProfile` gets `decision: []`, with the reason in its doc comment. The doc of `gatedRealProfileResidentContainerCount` now tells that the decision slot adds no container, and names `Router.acquire` (the old text named `Router.acquireModel`, which does not exist).
    - No router change. Reason: comment "Cause, with evidence", point 3. The cross-resolve gap is the new task ^0f5h2a2 (the user selects the scope).
    - RED (before the change, local 128 GB box): `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` ran 4 tests, failed with 6 issues: `:225` (4 spans, expected 3), `:226`, `:234`, `:265`, `:324`, `:325`. The `ResolutionFailure` does not occur locally, because the local budget is much larger than on `mini-01`.
    - What did not work / not chosen: a router change that counts the decider memory as free for a later trio. It loads over the budget. A revocable decision hold needs an Extras API (no API evicts a held model).

    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedRealProfile.swift. `--filter CrossRouterPoolIntegrationTests`: 4 tests in 1 suite passed. `--filter 'DecisionSlotIntegrationTests|GGUFProfileIntegrationTests'`: 7 tests in 2 suites passed. `--filter 'FoundationModelsRouterIntegrationTests\.IntegrationTests/'` (milestone 7, the other user of the gated profile; found by grep): 2 tests in 1 suite passed. Root `swift test` once: 2638 tests in 305 suites, 41 in 23, 19 in 3, all passed. Only warning: the existing build-system "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: /review
  timestamp: 2026-11-12T00:43:58.352712+00:00
position_column: doing
position_ordinal: '80'
title: Fix CrossRouterPoolIntegrationTests after the decision slot (CI run 43122216651)
---
## What
CI run https://github.com/swissarmyhammer/FoundationModelsRouter/actions/runs/43122216651 (commit 90b44602) failed in the Integration job. Build & test passed. 3 tests in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift` (suite "Gated real-model coverage: two live routers over one pool load a model one time") fail with 6 issues:
- `:225` `firstLoadSpans.count == gatedRealProfileResidentContainerCount`
- `:226` `modelRefs(of: firstLoadSpans) == distinctModelRefs(of: try #require(firstProfile))`
- `:218` and `:251` `ResolutionFailure: profile "integration-real" cannot co-fit a budget of 1155104301 bytes.`
- `:324` `fixture.router.loadSpans.count == gatedRealProfileResidentContainerCount - 1`
- `:325` `fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount`

Probable cause (verify first): the gated real profile (`integration-real`, see `gatedRealProfileResidentContainerCount` and the profile definition in `IntegrationTests/.../Support/` or `Tests/FoundationModelsRouterTestSupport`) now gets the default decision candidate `Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf`. When it fits, it is a fourth resident model and a fourth load span, and a test budget that is sized for three models does not fit. Find the real cause from the code and the CI log (`gh run view 43122216651 --log-failed`) before you change anything. Also explain the `ResolutionFailure`: the decision slot must never block a profile (R4). If the failure comes from the decision slot, it is a bug in the router, not only in the test; fix the router then.

Choose the fix that keeps the meaning of each test: these tests check cross-router pool sharing of the trio, not the decision slot. If the cause is only the extra decision model, give the gated real profile `decision: []` (the decision slot then shares the flash key and costs 0 bytes), or count the decision container where the test counts containers. Write the reason in a comment.

## Acceptance Criteria
- [x] The cause is stated in a task comment, with the evidence (code lines and log lines).
- [x] `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` passes locally, with a non-zero count of tests that ran.
- [x] `swift test --package-path IntegrationTests --filter 'DecisionSlotIntegrationTests|GGUFProfileIntegrationTests'` still passes.
- [x] Each other suite that uses the same gated real profile or `gatedRealProfileResidentContainerCount` is checked (grep) and still passes.

## Tests
- [x] The three failing tests in `CrossRouterPoolIntegrationTests.swift` pass.
- [x] Root `swift test` passes once.

## Workflow
- Use `/tdd` — reproduce the failure first, then fix. #decision