---
assignees:
- claude-code
depends_on:
- 01M77TVA831PXTF73N0QMSN6F3
position_column: todo
position_ordinal: '8280'
title: 'R13: Integration test of h2o-lightning-4b in the decision slot'
---
## What
Source: ../FoundationModelsDecision/plan.md section 14 (R13). The user approved the plan.

WAIT: this task waits for R12 (^qmsn6f3), and R12 waits for the shas of FoundationModelsDecision N3 and Extras E7.

- Add a gated test to `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/DecisionSlotIntegrationTests.swift` (or a new suite next to it, over `Support/IsolatedPoolRouter.swift`). It resolves a profile with `h2oai/h2o-lightning-4b-gguf` `h2o-lightning-4b-Q4_K_M.gguf` (2.71 GB) in the decision slot, at a pinned revision.
- It expects the native path (`PooledNativeDecisionModel`) in the decision slot, and asks one yes/no, one choice and one score question.
- Record the result (answers, probabilities, time) in a comment on this task and send it to the FoundationModelsDecision session. Then the user decides if h2o-lightning-4b becomes the default candidate (`ProfileDefinition.defaultDecisionCandidates`) in place of decider-4b. Do not change the default in this task.

## Acceptance Criteria
- [ ] The resolve puts h2o-lightning-4b in the decision slot on the native path.
- [ ] Each question kind gets an answer of its kind with probabilities in range that sum to 1, and a clear question gets the correct top answer.
- [ ] The result is recorded on this task.

## Tests
- [ ] The new gated test in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/`.
- [ ] `swift test --package-path IntegrationTests --filter <suite>` passes, with the test count checked.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision