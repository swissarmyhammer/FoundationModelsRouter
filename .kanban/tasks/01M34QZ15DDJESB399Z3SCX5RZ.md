---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37ghrky5qq5wn0zzsk912y1
  text: |-
    ### research and design choices

    - Current sites (2026-09-23): `JointFit.swift` had `marginNumerator`, `marginDenominator` and `withMargin` at lines 50-66, and `sizedReport` at lines 288-303. `Router.chosenSessionBytes` at line 646 called `JointFit.withMargin`. The card named `sessionKVBytes`; that function is now `chosenSessionBytes`.
    - Choice 1: `sizedReport` takes the raw charge as `chargedBytes` (the old name was `rawChargeBytes`). Its report carries the raw figures as they are. There is no other allowance and no new constant.
    - Choice 2: every doc comment that said "× 1.2" or "margined" now says "raw footprint estimate" or "raw KV cache estimate". This includes `Footprint.swift`, which said "the fit step applies its own margin".
    - Choice 3: test helpers renamed: `sessionKVMarginedBytes` became `sessionKVBytes`, `steppedDownSessionKVMarginedBytes` became `steppedDownSessionKVBytes`, `generationWeightsMarginedBytes` became `generationWeightsBytes`, and `generationSlotMarginedFootprint` / `embeddingSlotMarginedFootprint` became `generationSlotFootprint` / `embeddingSlotFootprint`. The expected figures are now the raw bytes: 12_097_152, 10_000_000, 2_097_152, 11_048_576, 1_048_576.
    - Choice 4: the merge test in `ResolveTests` sets its budget to the midpoint of the two slot footprints, so it adds no new number. The window budgets and the windows were computed again from the raw formula: JointFitTests `windowBigWindow` is 39_499, the router window test budget is 13_107_500, and the multitool window is 85_840.
    - Choice 5: the two tests that checked the margin are now tests of the raw figure: `reportFootprintIsTheRawEstimate` and `fitBoundaryIsInclusive`. The dedup test is now `sharedWeightsAreChargedOnceInTheDedupedTotal`.
    - `headroomBufferBytes` (a test-only 1_000) stays. Its doc no longer says that it absorbs a rounding difference, because no rounding remains.
  timestamp: 2026-09-23T16:11:01.118726+00:00
- actor: claude-code
  id: 01m37ghtq9dmvq145ngfq9bfpz
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsRouter/Resolution/JointFit.swift, Resolution/SlotResolution.swift, Resolution/ModelPool.swift, Router.swift, LanguageModelProfile.swift, Sizing/Footprint.swift, Tests/FoundationModelsRouterTests/JointFitTests.swift, ResolveTests.swift, Helpers/ResidencyStubs.swift. `swift test`: 1325 tests in 149 suites passed (2 known issues), 1 test in 1 suite passed, 19 tests in 3 suites passed. IntegrationTests build complete. The acceptance `rg` finds nothing in Sources, Tests or IntegrationTests.
    - next: commit, then review
  timestamp: 2026-09-23T16:11:03.273686+00:00
- actor: claude-code
  id: 01m37gsrv2wfzvx14x3xss774z
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 7e84db7 — 0 findings, 0 confirmed, 0 refuted; 14 validator pairs attempted, 0 failed; 9 files reviewed. The description has no open finding.
    - next: move to done
  timestamp: 2026-09-23T16:15:23.490374+00:00
- actor: claude-code
  id: 01m37gswxp241nk4s3feh9pxde
  text: |-
    ### finish iteration 1 — done
    - commits: 7e84db7 feat(sizing): delete the footprint overhead factor; the fit compares the raw estimate
    - `swift test`: "Test run with 1325 tests in 149 suites passed after 6.803 seconds with 2 known issues."; "Test run with 1 test in 1 suite passed"; "Test run with 19 tests in 3 suites passed".
    - `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - review passes: 1 (clean, 0 findings). Card moved to done.
  timestamp: 2026-09-23T16:15:27.670663+00:00
depends_on:
- 01M34PGWP0GS427JNWAAMKPZPW
position_column: done
position_ordinal: fffff580
title: Remove the × 1.2 footprint margin from the fit test
---
## Decision (from the owner, 2026-09-22)

`JointFit.withMargin` (`Resolution/JointFit.swift:49-65`, `marginNumerator` 6 / `marginDenominator` 5, × 1.2) is an invented overhead factor and must go. The fit test compares the raw footprint estimate against the budget.

## Why

- It came from commit e4ac70b (2026-06-30) with no measurement and no reason for the number.
- Overhead exists (Metal buffer alignment, allocator slack, activations), but it is not proportional to the footprint. A factor guesses both the size and the shape of it.
- Two overhead allowances already sit under it: the budget is `min(recommendedMaxWorkingSetSize, totalRAM − headroomReserve)` (`Sizing/HostProfile.swift:72`). Metal's working-set figure is the machine's own statement, and `headroomReserve` is host-set.
- With ^amkpzpw the margin would make every computed window 17% smaller than memory allows, for no measured reason.

## Sites

- `JointFit.swift:49-65`: the two constants and `withMargin`.
- `JointFit.swift:300-305` `sizedReport`: `charged` and `estimatedFootprintBytes` use the raw bytes.
- `Router.swift:673` `sessionKVBytes`: return the raw bytes.
- `ModelPool.swift:53-58, 96` and `LanguageModelProfile.swift:25, 139`, `SlotResolution.swift:29, 55-61`, `JointFit.swift:33, 292-293`: doc comments that say "× 1.2" or "margined". Rewrite each to say the raw estimate.
- `Tests/`: every fixture that computes an expected charge with × 1.2 (for example `ResidencyStubs.swift:198` `sessionKVMarginedBytes`, `JointFitTests`, `ModelPoolTests`). Change the expected numbers to the raw bytes, and rename the helpers that say "margined".

## Do this

1. Delete the two constants and `withMargin`. Every caller uses the raw bytes.
2. Rewrite the doc comments above.
3. Update the test expectations and helper names.
4. Do not add any other allowance. If a live load ever fails at the budget line, record the measurement on a new card; do not add a factor.

## Acceptance

- `rg 'withMargin|marginNumerator|marginDenominator|margined|× 1\.2|x 1\.2'` finds nothing in `Sources` or `Tests`.
- All tests pass.

## Order

After ^amkpzpw (the ladder card), which uses the fit test this card changes. #compaction #limits