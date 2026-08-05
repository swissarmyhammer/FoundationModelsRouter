---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: '[Router] Flaky test: HumanWaitGateTests "a turn parked in awaitingUser frees the per-model gate, so another session over the same model still generates"'
---
Observed 2026-08-05 during full `swift test` runs while working ^ew49xjj (no code under test changed between runs — only a test rename in ToolOutputCappingTests.swift):

- Run 1: green (721/69 suites).
- Run 2: `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift` — Test "a turn parked in awaitingUser frees the per-model gate, so another session over the same model still generates" recorded an issue: `Expectation failed: await fixture.observer.exited == ["b"]` (suite "Human waits release the per-model generation gate, never the per-session turn lock").
- Run 3 (immediately after, same tree): green.

Timing-sensitive concurrency assertion — the observer's exited list presumably races the parked turn's gate release. Diagnose the race in the test (or the gate, if the race is real) and make the test deterministic — e.g. wait on the gate-released signal before asserting `observer.exited`, rather than relying on scheduling order.

## Acceptance Criteria
- [ ] Root cause identified (test-side race vs product-side race) and recorded on this card
- [ ] The test passes deterministically (e.g. repeated runs / `swift test --filter HumanWaitGateTests` in a loop stay green)
- [ ] No product behavior change unless the race is proven product-side #router-first #flaky-test