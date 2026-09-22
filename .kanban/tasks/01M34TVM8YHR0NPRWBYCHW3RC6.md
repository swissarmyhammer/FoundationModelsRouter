---
assignees:
- claude-code
position_column: todo
position_ordinal: '9280'
title: Delete backgroundRunDrainRoundLimit; the drain runs until no new background work starts
---
## Decision (from the owner, 2026-09-22)

`RoutedSessionActor.backgroundRunDrainRoundLimit` (4, `Session/RoutedSessionActorGeneration.swift:8`) is an invented count and must go. The drain after a turn runs until a round starts no new background work, or the caller cancels.

## Why

- No reason for 4 is recorded. It predates the 2026-08-25 vocabulary rename.
- The loop already has its exits: `settleBackgroundRuns` returns `false` when the run plane is empty, and the loop breaks (`:74, 92-94`); a cancellation breaks it (`:73`). The count only cuts off a model that starts more background work in every round, silently, with the runs still going.

## Sites

- `RoutedSessionActorGeneration.swift:4-8`: the constant and its doc. `:24-30`: the `respond` doc that names it. `:65` the `for _ in 0..<Self.backgroundRunDrainRoundLimit` loop.
- Any other `respond`-like entry point that drains (`streamResponse`, guided respond); search `backgroundRunDrainRoundLimit`.
- Tests that assert the fourth round ends the drain (`RespondRunPlaneDrainTests`).

## Do this

1. Delete the constant. Replace the counted `for` with a `while true` loop whose exits are the two that exist: no new background work, and cancellation.
2. Rewrite the docs that name the count.
3. Replace the test that asserts the cut-off with one where a scripted model starts a background run in each of 6 rounds and then none: the drain runs 7 rounds and the answer is the seventh turn's.
4. Do not add a count anywhere else.

## Acceptance

- `rg 'backgroundRunDrainRoundLimit'` finds nothing.
- The 7-round test passes. All tests pass. #compaction #limits