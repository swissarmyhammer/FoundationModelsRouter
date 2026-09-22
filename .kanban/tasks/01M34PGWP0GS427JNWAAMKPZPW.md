---
assignees:
- claude-code
depends_on:
- 01M34PDQHD1WEJ2QBYPJ0P7ZN0
position_column: todo
position_ordinal: '8580'
title: Replace the context ladder with the largest window that fits
---
## Decision (from the owner, 2026-09-22)

`JointFit.ladderStepDowns` (131,072 / 65,536 / 32,768 / 16,384 / 8,192 / 4,096, `Resolution/JointFit.swift:57`) is an invented list and must go. When a model's KV cache at its native window does not fit in memory, the router computes the largest window that fits and reports it. The number comes from the model and the machine, not from a list.

## What exists

- `Footprint.kvBytes(context:)` (`Sizing/Footprint.swift:72`) is linear in `context`: `2 × layers × context × kvHeads × headDim × 2`. So bytes per token is a known constant for a model, and the largest context under a byte budget is one division.
- `JointFit.walkLadder` (`JointFit.swift:409`) tries `attemptTrio` at each rung, largest first, and stops at the first rung where the whole trio (standard, flash, embedding) co-fits `budgetBytes`. `contextLadder` (`:383`) builds the rung list.
- `LadderAttempt` records each rung tried, with its footprint and the blocked slot. `CandidateReport.ladderAttempts` carries them into the resolution report.
- `JointFit.withMargin` applies × 1.2 to every footprint. This card keeps the margin as it is. It is an open question for the owner, in the limits inventory of 2026-09-22.

## Do this

1. Delete `ladderStepDowns` and `contextLadder`.
2. Replace `walkLadder` with one computation for a standard candidate: the largest `context` in `1...nativeMaxContext` at which `attemptTrio` succeeds. Because the KV bytes are linear in `context` and every other charge in the trio is fixed at that point, derive it directly: the bytes left for the standard slot's KV cache after the weights, the margin and the other slots' charges, divided by the bytes per token, floored, then capped at `nativeMaxContext`. Confirm the result with one `attemptTrio` call at that context. When the result is below 1, the candidate does not fit.
3. Keep the report. Replace the list of rung attempts with one record that states the native window, the computed window, and the blocked slot when nothing fits. Rename `LadderAttempt` and `CandidateReport.ladderAttempts` to names that say "fit" and not "ladder", so the words match the mechanism.
4. A profile with an explicit `context` still uses that context and skips the computation, as today (`JointFit.swift:144`).
5. Update the tests in `JointFitTests.swift` that assert rung sequences. Add tests: a model that fits at its native window gets the native window; a model that does not fit at native gets the computed window, and `attemptTrio` at that window plus one fails; a model that does not fit at 1 token is reported as not fitting.

## Acceptance

- `rg 'ladderStepDowns|contextLadder|walkLadder|LadderAttempt|ladderAttempts'` finds nothing.
- The tests above pass. All tests pass.
- The resolution report for a model that did not fit at native states the native window and the computed window.

## Order

After ^j0p7zn0 (it edits the `contextLadder` cap line this card deletes). Before ^24hrxdj (Make the model's window the default context of a profile). All three edit `JointFit.swift`. #compaction #limits