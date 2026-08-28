---
assignees:
- claude-code
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: todo
position_ordinal: '8180'
title: Open one span for each generation turn
---
## What

Wrap each generation turn in one span, at the one point all turn entries flow through.

- Instrument `RoutedSessionActor.runTurn` (Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:103). Every surface uses this path: `respond(to:maxTokens:)`, `streamResponse(to:maxTokens:)`, `streamEvents(to:maxTokens:)`, and `dispatchNextPrompt()`. The delivery-turn path `runDispatchedTurn` (line 534) also reaches it at line 540, so one span here covers all of them.
- Span name: `FoundationModelsRouter.turn` from `RouterTracing`. Kind: `.client`.
- Attributes: `router.id`, `session.id`, `model.ref`, `turn.id`, and the turn entry point (`respond`, `stream`, or `dispatch`).
- After a good turn, set the measured token counts from the turn's usage snapshot (see `usageState` and Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift) as the `tokens.in` and `tokens.out` attributes.
- A turn that throws must record the error on the span and throw again. `withSpan` gives this. A cancelled turn records `CancellationError`.
- Do not put prompt text or response text in an attribute; the shared no-leak test from the foundation task covers this.
- Extend the doc comments on the `RoutedSession` protocol methods to state the span contract, as `RoutedEmbedder.embed` does.

## Acceptance Criteria
- [ ] One `respond` call makes exactly one turn span with the named attributes.
- [ ] One streamed turn and one dispatched turn each make one turn span.
- [ ] A failed turn keeps its span, with the error recorded.
- [ ] With `InstrumentationSystem` left unbootstrapped and no explicit tracer, the existing turn suites pass unchanged.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/TurnTracingTests.swift`. Use `InMemoryTracer` and the scripted fixtures (`Tests/FoundationModelsRouterTests/Helpers/ScriptedSessionFixture.swift`, `StubSessionBackend.swift`). Model the suite on `EmbedTracingTests.swift`.
- [ ] Assert the span name, kind, attributes, token attributes, and the error record for a turn that throws.
- [ ] Add one case that runs a turn with no tracer injected and no backend bootstrapped, and asserts the turn returns its normal response.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router