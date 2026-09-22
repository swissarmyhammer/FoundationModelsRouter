---
assignees:
- claude-code
depends_on:
- 01M34PGWP0GS427JNWAAMKPZPW
position_column: todo
position_ordinal: '8980'
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