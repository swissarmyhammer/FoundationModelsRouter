---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: '`resolve real profile, then generate, embed, guide, fork, and record` measured 89.8 seconds, 75 percent of the two-minute budget'
---
Filed by task ^6ww73dm, which moved `RealToolTurnComparisonTests` under half of `integrationTestBudgetMinutes`. The two whole-target runs of 2026-08-21 after that move (runs 6 and 7 in the table in the doc comment of `integrationTestBudgetMinutes`) measured this test of `RealModelEndToEndIntegrationTests` at 89.8 and 55.0 seconds. The earlier runs measured 46.6, 48.7, 44.9, 84.9 and 60.9. The 89.8 is 75 percent of the budget and the largest number of runs 6 and 7. The box ran a GPU-heavy game for both runs, so some of the spread is the box; measure on a quiet box first.

## Acceptance Criteria

- [ ] The test measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [ ] No assertion is weakened and the budget is not raised
- [ ] The suite doc states what the conversion no longer proves, as `SessionTreeRestorationIntegrationTests` does
- [ ] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt