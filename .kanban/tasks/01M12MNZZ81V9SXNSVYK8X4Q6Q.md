---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14jtc8pwds76w8cgb7zdbe1
  text: |-
    Research notes, for the next agent.

    - The span site is a helper, `withForkSpan(_:)`, that mirrors `withCompactionSpan(trigger:_:)` in RoutedSessionActorCompaction.swift. `fork(workingDirectory:)` is now only that helper plus a call to a new `private func performFork(workingDirectory:)`, which holds the unchanged mechanics. This keeps the span open before the reentry guard and before `forkAdmissionGate.wait()`, which is what the card requires.
    - The child session id needed a new key. `session.id` already names the parent, so `RouterTracing.AttributeKey.forkChildSessionId` = `fork.child_session_id` was added to the one vocabulary home. It is written only after the child exists, so a refused fork carries no such key.
    - Removed the `// periphery:ignore` marker on `RouterTracing.SpanName.fork`. No other marker had to go: `routerId`, `sessionId` and `modelRef` already had callers.
    - `InMemoryTracer` gives `activeSpans` beside `finishedSpans`. That is how the ceiling test reads an OPEN span while the gate still has a waiter, with no wall-clock assertion at all.
    - The refusal test drives a real tool call through `ScriptedSessionFixture`. A String-output tool reaches `RunToCompletionRunner`, which opens the `.toolCall` window on `GenerationPermitLoan`, which is what makes `isInsideOwnTurnToolCall` true. The tool catches the refusal and answers with a marker, so the turn completes and the answer says which branch ran.
    - `RouterTestFixtures.makeRouter` had no `maxConcurrentForks` parameter. One was added, with the package default, rather than copying `ForkConcurrencyTests`'s own private router factory. The fixtures in ForkConcurrencyTests.swift are `private` and no other file can reach them, so the suite uses the same shapes from the shared helper home.
  timestamp: 2026-08-28T16:21:33.590903+00:00
- actor: claude-code
  id: 01m14jtybt6n1na4atgw5dwpp6
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Tracing/RouterTracing.swift, Tests/FoundationModelsRouterTests/ForkTracingTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift. TDD: the 3 new span tests failed first with 9 issues (no fork span existed), then passed. `swift build` complete. `swift test` = 1090 tests in 113 suites passed with the 2 known issues, plus 83 eval tests passed; baseline was 1086 in 112 suites, so the difference is exactly the new 4-test `Fork tracing` suite. `swift build --package-path IntegrationTests --build-tests` complete.
    - next: /review
  timestamp: 2026-08-28T16:21:52.122867+00:00
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: doing
position_ordinal: '80'
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
- [x] One fork makes one span with the parent and child session ids.
- [x] A fork refused by the reentry guard still produces a span, with the error recorded.
- [x] A fork that waits on the ceiling has that wait inside its span.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/ForkTracingTests.swift`. Use `InMemoryTracer` with the fixtures from `ForkConcurrencyTests.swift`.
- [x] Assert the span name and attributes for a normal fork.
- [x] Assert a fork refused from inside a tool of its own turn records `SessionReentryError.forkDuringSameSessionTurn` on a span that exists.
- [x] For the ceiling wait, hold the ceiling with in-flight forks, then assert the queued fork's span is open before its slot frees. Use the bounded-wait helpers (`Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`); do not assert on wall-clock durations.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router