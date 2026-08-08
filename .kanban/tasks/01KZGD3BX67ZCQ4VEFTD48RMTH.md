---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Make the metallib bootstrap trigger structural, not per-test discipline
---
Follow-up to `^ce4hb6n`, which ported `MetalLibraryTestBootstrap` and wired it in. The wiring works today — audited, all 22 gated live tests reach `ensureColocatedMetallib` before any model resolution — but it rests on convention, and the failure mode when convention breaks is severe.

The bootstrap installs a symlink beside the running test binary and must run before the first GPU-device `MLXArray` evaluation, otherwise mlx aborts THE WHOLE TEST PROCESS with "Failed to load the default metallib". It is triggered from exactly three chokepoints:
- `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` — inside `shared`'s initializer
- `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift` — in `container()`
- `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift` — in `container()`

For the integration target that means all 20 gated `@Test` bodies must each remember to touch `GatedSuiteSerialGate.shared` as their first statement. All 20 currently do (19 via `withPermit`, `IntegrationTests.endToEnd` via `wait()`/`defer signal()`). Nothing enforces it. A new gated `@Test` written without that line does not fail an assertion — it crashes the entire test process on first GPU evaluation, taking every other suite's results with it, with an error message that points at mlx rather than at the missing line.

The same latent gap exists in Evals: a third live entry point that does not route through a bootstrap-touching `container()` would crash that process the same way.

Suggested direction (not prescriptive): a suite-level `TestScoping` trait applied to each gated `@Suite` that touches the bootstrap and takes the permit, making both concerns structural and removing the per-test requirement entirely. Note the constraint the port already discovered — `.evaluates(...)` is itself a `TestScoping` trait that runs inference ahead of the `@Test` body, which is exactly why the Evals target triggers from `container()` rather than a test body; any trait-based design must order correctly against it.

## Acceptance Criteria
- [ ] A newly added gated `@Test` that forgets the per-test gate line cannot crash the process on metallib — demonstrated, not asserted
- [ ] Ordering against `.evaluates(...)`'s own `TestScoping` behavior is handled and documented
- [ ] The three existing chokepoints are reduced to whatever the new mechanism needs, with no duplicate trigger left behind
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` still shows zero metallib errors in both gated targets
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Gated run confirming both targets still bootstrap. Gated runs: one at a time, one shell command per run. #phase-1