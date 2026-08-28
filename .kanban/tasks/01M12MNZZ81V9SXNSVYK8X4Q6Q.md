---
assignees:
- claude-code
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: todo
position_ordinal: '8580'
title: Open one span for each session fork
---
## What

Wrap each session fork in one span. The span must include both the reentry guard and the wait for a free fork slot, so a refused fork still gets a span and a queued fork shows its wait.

- Instrument the fork path in Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, behind `RoutedSession.fork(workingDirectory:)`.
- Open the span as the first statement of `fork(workingDirectory:)` — before the reentry guard that throws `SessionReentryError.forkDuringSameSessionTurn` (around line 36), and before `await forkAdmissionGate.wait()` (around line 44). Opening it after the guard would leave a refused fork with no span, which contradicts the criterion below.
- Span name: `FoundationModelsRouter.fork` from `RouterTracing`. Kind: `.internal`.
- Attributes: `router.id`, `model.ref`, the parent `session.id`, and, on success, the child `session.id`.
- A fork that throws must record the error on the span and throw again.

## Acceptance Criteria
- [ ] One fork makes one span with the parent and child session ids.
- [ ] A fork refused by the reentry guard still produces a span, with the error recorded.
- [ ] A fork that waits on the ceiling has that wait inside its span.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/ForkTracingTests.swift`. Use `InMemoryTracer` with the fixtures from `ForkConcurrencyTests.swift`.
- [ ] Assert the span name and attributes for a normal fork.
- [ ] Assert a fork refused from inside a tool of its own turn records `SessionReentryError.forkDuringSameSessionTurn` on a span that exists.
- [ ] For the ceiling wait, hold the ceiling with in-flight forks, then assert the queued fork's span is open before its slot frees. Use the bounded-wait helpers (`Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`); do not assert on wall-clock durations.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router