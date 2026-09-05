---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1sfkzxhwsyy99ec11fq0qcy
  text: |-
    Research before the change:
    - `PoolEntry.footprintBytes` is `max(baseFootprintBytes, acquiredChargeBytes)`. `baseFootprintBytes` is the first load's whole margined footprint (weights plus that load's KV cache). `ResidencyHold.chargedBytes` is the whole JointFit charge, so the first hold gives back weights plus KV cache and a later hold gives back its KV cache only.
    - `Router.runResolve` gets the whole margined footprint from `chosenFootprint(for:)` and the charge from `chosenCharge(for:)`. `Router.sessionBytes(for:context:metadataByRef:)` gives the raw KV cache bytes at a context. `JointFit.withMargin` applies the `x 1.2` margin.
    - Canned fixture arithmetic (2-layer config, 10_000_000-byte shard): weights margined = 12_000_000; KV at 8192 raw 2_097_152, margined 2_516_583; KV at 4096 raw 1_048_576, margined 1_258_292; whole at 8192 = 14_516_583; whole at 4096 = 13_258_292. Whole less own KV cache is 12_000_000 at both contexts.
    - RED scenario: narrow trio at 4096 (38_516_584) then wide at 8192 reusing the standard ref (charge 29_033_166). Host = 67_550_750. After the narrow release the correct hold is 41_033_166, so the budget a failing resolve reports is 26_517_584. The current `max` floor holds 39_774_875 and reports 27_775_875: under-charged by 1_258_291.
    - Design: `PoolEntry.baseWeightsBytes` = first load's margined footprint less its margined KV cache; `acquiredChargeBytes` = sum of the live holds' margined KV caches; `footprintBytes = baseWeightsBytes + acquiredChargeBytes`. `ModelPool.acquire` takes `footprintBytes` and `sessionBytes`; `ResidencyHold` carries `sessionBytes` (zero for an embedder). `Router` computes the margined session bytes from `sessionBytes(for:context:metadataByRef:)`. `chosenCharge(for:)` then has no caller and is deleted.
    - The repo holds no formatter config (no `.swiftformat`, `.swift-format`, `.swiftlint.yml`) and the files do not pass `swiftformat --lint` or `swift format lint` as they are. The change follows the file's own style by hand.
  timestamp: 2026-09-05T19:09:41.681122+00:00
- actor: claude-code
  id: 01m1sfvt57jaj7hms3s6dptf39
  text: |-
    Implementation landed (TDD):
    - RED: `releasingTheFirstContextHoldLeavesOnlyTheRemainingKVCharged` failed on the `max` floor with `failure.budgetBytes` 27_775_875 against the expected 26_517_584, an under-charge of 1_258_291.
    - GREEN: `PoolEntry` now stores `baseWeightsBytes` (the first load's margined footprint less its margined KV cache) and `footprintBytes = baseWeightsBytes + acquiredChargeBytes`. `ModelPool.acquire` takes `sessionBytes` in place of `chargedBytes`; `ResidencyHold.sessionBytes` is the KV share a release gives back. `Router.acquireModel` builds the `AcquiredSlot` itself, `acquireEmbedder` passes zero session bytes, `Router.chosenSessionBytes(for:context:metadataByRef:)` gives the margined KV cache, and `chosenCharge(for:)` is deleted because nothing calls it.
    - New fixture constants in `ResidencyStubs.swift`: `generationWeightsMarginedBytes`, `steppedDownTrioFootprint`, `reuseWithOwnFlashAndEmbedderCharge`, `wideHoldAfterNarrowRelease`, each with its arithmetic in the doc comment.
    - `model-pool.md` §2.3 names `sessionBytes` on `ResidencyHold`.
    - All 17 `PooledResidencyTests` pass with the existing numbers unchanged.

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Resolution/ModelPool.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/Helpers/ResidencyStubs.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift, model-pool.md
    - next: /test
  timestamp: 2026-09-05T19:13:57.927280+00:00
- actor: claude-code
  id: 01m1sfwakg8sa6r11rc77wgnar
  text: |-
    ### test — green
    - evidence: `swift test` — 1236 tests in 134 suites passed (2 pre-existing known issues, `RealModelHarness.swift` and `BoundedWait.swift`) and 83 tests in 10 suites passed; 0 failures, 0 skipped; no compiler warning (the one `missing creator for mutated node` line is the SwiftPM mlx bundle warning present before this change). `swift build --package-path IntegrationTests --build-tests` — exit 0.
    - next: /commit
  timestamp: 2026-09-05T19:14:14.768511+00:00
position_column: doing
position_ordinal: '80'
title: Charge the weights once and every KV cache per hold, whatever the release order
---
Found by the holistic double-check of branch `pool` (2026-09-05). Plan: `model-pool.md` §2.3.

## What
`PoolEntry.footprintBytes` in `Sources/FoundationModelsRouter/Resolution/ModelPool.swift` is `max(baseFootprintBytes, acquiredChargeBytes)`, and `baseFootprintBytes` is the first load's whole margined footprint: weights plus that load's own KV cache. Since the key carries no context (commit `ac39499`), one entry can hold two contexts, and the floor is wrong after the first-context hold is released.

Model M loaded first at 8k, reused at 32k:
- first hold charges `margin(W + KV8k)` and sets `base` to the same value;
- second hold charges `margin(KV32k)`;
- release the 8k profile: `acquiredCharge = margin(KV32k)`;
- `footprintBytes = max(margin(W + KV8k), margin(KV32k)) = margin(W + KV8k)`.

The pool holds `W + KV32k` and charges `W + KV8k`. The budget is under-charged by `margin(KV32k - KV8k)`, and the next resolve believes it has memory it does not have.

Fix: keep the weights and the KV caches apart in the entry.
- Replace `baseFootprintBytes` with `baseWeightsBytes`: the first load's margined footprint less its own margined KV cache. `Router` knows both numbers at acquisition: `chosenFootprint(for:)` and `sessionBytes(for:context:metadataByRef:)` (apply `JointFit.withMargin`).
- `footprintBytes` becomes `baseWeightsBytes + acquiredChargeBytes`, where the first hold's charge stays weights plus its KV cache, as `JointFit.sizedReport` gives it, and every later hold's charge is its own KV cache.
- Check that the sum after every release is exactly the weights plus the KV caches of the holds that remain. The existing pins in `PooledResidencyTests` (`sharedGenerationPairHoldsBothKVCachesAgainstTheBudget`, `releasingOneHolderOfSharedPairGivesBackOnlyItsShare`, `reusingResidentGenerationModelChargesOneSessionKVCache`, `secondContextChargesOnlyItsOwnSessionKVCache`) must keep passing with the same numbers.

## Acceptance Criteria
- [x] Resolve at `ResidencyFixtures.steppedDownContext` first, then at the default context, release the narrow profile: the budget a third failing resolve reports equals the host budget less weights, less the wide profile's KV cache, less the embedder, with nothing of the narrow KV cache left charged.
- [x] The same in the other order still gives the numbers the existing tests pin.
- [x] `swift test` → green.

## Tests
- [x] New test in `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift`: `releasingTheFirstContextHoldLeavesOnlyTheRemainingKVCharged` (RED first: it must fail on the current `max` floor by the exact under-charge).
- [x] Run `swift test --filter PooledResidencyTests` → all pass. Run `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #defect #router