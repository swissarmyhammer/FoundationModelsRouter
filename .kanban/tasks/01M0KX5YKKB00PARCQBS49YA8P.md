---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: '`MLX path: whether the ToolContext bound around respond() arrives` measured 118.7 seconds, 99 percent of the two-minute budget'
---
Filed by task ^pa5q5dt, which took `resolve real profile, then generate, embed, guide, fork, and record` under half of `integrationTestBudgetMinutes`. The two whole-target runs of 2026-08-22 after that change (runs 8 and 9 in the table in the doc comment of `integrationTestBudgetMinutes`) measured this test of `PropagationProbeIntegrationTests` at 60.6 and 118.7 seconds. The 118.7 is 99 percent of the budget, and this test is now the nearest to the limit in the target.

The spread is the widest of the whole table: runs 1 to 7 measured it at 67.2, 27.4, 24.4, 85.5, 68.5, 21.0 and 35.7 seconds, so the number moves by a factor of five with no code change to the suite. That shape says the turn takes the provider's default sampling and states no reply ceiling, which is what task ^pa5q5dt found under the end-to-end resolution test: the 30B writes a `<think>` block of a different length on every run. Read `IntegrationTests` and `RealToolTurnComparisonTests` for the two shapes of that repair, and add a per-phase clock before choosing one.

A test the limit cancels is worse than a plain red result. The cancellation lands mid-generation, and a cancellation on GPU work aborts the whole process on a Metal assertion (fork card ^3axg80k), which takes every other suite's results with it. At 99 percent of the budget this test is one slow run away from that.

The box ran a GPU-heavy game for both runs, at load average 12.0 and 14.6, so some of the spread is the box. Measure on a quiet box first.

## Acceptance Criteria

- [ ] The test measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [ ] No assertion is weakened and the budget is not raised
- [ ] The suite doc states what the conversion no longer proves, as `IntegrationTests` and `SessionTreeRestorationIntegrationTests` do
- [ ] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt