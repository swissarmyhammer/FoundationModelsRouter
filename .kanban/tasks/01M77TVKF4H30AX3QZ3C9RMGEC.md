---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79j1gmtr5w530ycyj4f1g7j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — DecisionSlotIntegrationTests: `nativeDeciderModel` (h2oai/h2o-lightning-4b-gguf, h2o-lightning-4b-Q4_K_M.gguf, revision 61f8d8b7a8c2d84426d0d143ca187f65d235934b), `nativeDeciderProfile`, test "a GGUF decision model with a supported decision type takes the native path and answers each kind".
    - test: green — `swift test --package-path IntegrationTests --filter DecisionSlotIntegrationTests`: 4 tests in 1 suite passed after 24.200 seconds.
    - commit: 2c132b8b
    - review: findings — DecisionSlotIntegrationTests.swift:414 (the native test repeats the item loop of the reference test).

    ### finish iteration 2 — clean
    - implement: changed — `DecisionSlotProbe.askEachReferenceItem(on:check:)` holds the shared loop; both tests use it.
    - test: green — 4 tests in 1 suite passed after 27.059 seconds.
    - commit: 700d9d05
    - review: clean — 0 findings.

    ### Result (2026-11-12, Apple silicon, Metal, native path PooledNativeDecisionModel)
    - binary-invoice-paid: no 0.0704, yes 0.9296 — 1.75 s (first call, includes warm-up)
    - choice-department-billing: billing 0.9492, technical 0.0276, sales 0.0232 — 0.060 s
    - score-toxicity-high: not toxic 0.0124, slightly toxic 0.0616, very toxic 0.9260 — 0.060 s
    - Each top answer is the top answer of the decider-2b Metal reference. The default candidate is not changed: the user decides if h2o-lightning-4b replaces decider-4b.
  timestamp: 2026-11-13T04:18:21.978069+00:00
depends_on:
- 01M77TVA831PXTF73N0QMSN6F3
position_column: done
position_ordinal: ffffffffff8d80
title: 'R13: Integration test of h2o-lightning-4b in the decision slot'
---
## What
Source: ../FoundationModelsDecision/plan.md section 14 (R13). The user approved the plan.

WAIT: this task waits for R12 (^qmsn6f3), and R12 waits for the shas of FoundationModelsDecision N3 and Extras E7.

- Add a gated test to `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/DecisionSlotIntegrationTests.swift` (or a new suite next to it, over `Support/IsolatedPoolRouter.swift`). It resolves a profile with `h2oai/h2o-lightning-4b-gguf` `h2o-lightning-4b-Q4_K_M.gguf` (2.71 GB) in the decision slot, at a pinned revision.
- It expects the native path (`PooledNativeDecisionModel`) in the decision slot, and asks one yes/no, one choice and one score question.
- Record the result (answers, probabilities, time) in a comment on this task and send it to the FoundationModelsDecision session. Then the user decides if h2o-lightning-4b becomes the default candidate (`ProfileDefinition.defaultDecisionCandidates`) in place of decider-4b. Do not change the default in this task.

## Acceptance Criteria
- [x] The resolve puts h2o-lightning-4b in the decision slot on the native path.
- [x] Each question kind gets an answer of its kind with probabilities in range that sum to 1, and a clear question gets the correct top answer.
- [x] The result is recorded on this task.

## Tests
- [x] The new gated test in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/`.
- [x] `swift test --package-path IntegrationTests --filter <suite>` passes, with the test count checked.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision