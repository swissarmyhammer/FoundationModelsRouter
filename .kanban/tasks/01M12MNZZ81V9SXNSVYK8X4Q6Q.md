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

Wrap each session fork in one span. The span must include the wait for a free fork slot, so its duration shows contention on the fork ceiling.

- Instrument the fork path in Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, behind `RoutedSession.fork(workingDirectory:)`.
- Span name: `FoundationModelsRouter.fork` from `RouterTracing`. Kind: `.internal`.
- Attributes: `router.id`, `model.ref`, the parent `session.id`, and, on success, the child `session.id`.
- Start the span before the wait on the fork-ceiling semaphore, so a queued fork shows a long span.
- A fork that throws (for example `SessionReentryError.forkDuringSameSessionTurn`) must record the error on the span and throw again.

## Acceptance Criteria
- [ ] One fork makes one span with the parent and child session ids.
- [ ] A fork that waits on the ceiling shows the wait inside the span duration.
- [ ] A refused fork keeps its span, with the error recorded.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/ForkTracingTests.swift`. Use `InMemoryTracer` with the fixtures from `ForkConcurrencyTests.swift`.
- [ ] Assert the span name, the attributes, and the error record for a refused fork.
- [ ] For the ceiling wait, hold the ceiling with in-flight forks, then assert the queued fork's span is open before its slot frees. Use the bounded-wait helpers (`Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`); do not assert on wall-clock durations.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router