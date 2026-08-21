---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: RealToolTurnComparisonTests both-surfaces test measures 109 to 111 seconds, 92 percent of the two-minute budget
---
Filed by task ^bpwfbyz, which converted the two tests that ran nearest the budget on 2026-08-20. The two whole-target runs of 2026-08-21 (`swift test --package-path IntegrationTests`, every model in the Hugging Face cache, runs 4 and 5 in the table in the doc comment of `integrationTestBudgetMinutes`) measured `RealToolTurnComparisonTests/realTurnDeliversToolDataOnBothSurfaces` at 109.4 and 110.7 seconds. That is 92 percent of `integrationTestBudgetMinutes` and the dearest test of the target now. The three runs of 2026-08-20 measured it at 86.7, 85.3 and 85.8 seconds.

The test already pins `.greedy`. It loads `RealModels.standard` (the 30B) twice and drives two multi-round tool turns, one through `respond(to:)` and one through `streamEvents(to:)`. The 30B decodes near ten tokens a second on the measuring box, and writes a `<think>` block before each round.

Note from ^bpwfbyz: the box ran a GPU-heavy game during both runs of 2026-08-21, so some of the growth from 86 to 110 seconds is the box. Measure on a quiet box first.

## Acceptance Criteria

- [ ] `realTurnDeliversToolDataOnBothSurfaces` measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [ ] No assertion is weakened and the budget is not raised
- [ ] The suite doc states what the conversion no longer proves, as `SessionTreeRestorationIntegrationTests` does
- [ ] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt