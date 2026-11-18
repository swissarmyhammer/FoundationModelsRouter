---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffffa880
title: Make ConsecutiveRecoveryBudgetTests/keyReorderedRepeatIsNoProgress deterministic under full-suite load
---
## Problem

On 2026-11-18 one full `swift test` run (2865 tests) failed with 2 issues in one test:

- `ConsecutiveRecoveryBudgetTests/keyReorderedRepeatIsNoProgress` ("a recovery followed by a call that repeats an earlier one in another key order does not start the count again").
- Error: `call 4 held for a stop, and no stop of the session came inside 10.0 seconds` (from `RepeatingReasoningModel.stopHoldLimit`, `Tests/FoundationModelsRouterTests/RepeatingReasoningModel.swift`).

The suite alone passed (6 tests in 0.087 seconds). The change in the same working tree (^swq7jnm, default session names) does not touch the recovery budget.

## Cause

The test depends on time: the fake model holds a call for a stop, and gives up after 10 seconds. Under the load of the full suite the stop did not come in that time. The suite also has `.timeLimit(.minutes(1))`.

## Change

- Make the test deterministic: the fake model must wait for the event of the stop, not for a time limit. Do not make the limit longer, do not add sleeps or retries.
- Remove the `.timeLimit` trait of the suite (repo rule: no test time limits).

## Tests

- [ ] The test passes in the full suite with no time-based wait.