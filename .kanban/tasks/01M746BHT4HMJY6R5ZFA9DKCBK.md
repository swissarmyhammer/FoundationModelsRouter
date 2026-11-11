---
assignees:
- claude-code
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: todo
position_ordinal: '8880'
title: 'R10: decide span with no state text and no answers'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R10. The model is the `embed` span in `Sources/FoundationModelsRouter/RoutedEmbedder.swift`.

- `Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift`: add `SpanName.decide` (`"decide"` or the name form that the other spans use) and `AttributeKey.decisionQuestionCount = "decision.question_count"`.
- `DecisionSession` is in the Decision package, so the router cannot wrap its methods. New `Sources/FoundationModelsRouter/Tracing/TracedDecisionModel.swift`: a `DecisionModel` that wraps the `decisionModel` of the container. Its executor wraps the `DecisionModelExecutor` of the inner model; each `decide(questions, state)` call runs inside `RouterTelemetry.withSpan(.decide, ofKind: .client, tracer:)` with `router.id`, `model.ref` and `decision.question_count`. `prewarm(for:)` passes through with no span. On a throw, the span gets the error status and the error type only (the existing `withSpan` rule).
- `RoutedDecider.makeSession(state:)` makes the session over the traced model, with the `tracer` and `routerId` of the handle.
- The span holds no state text, no question text, no option text and no answer value. Note this in the DocC, the same as the embed span DocC.

## Acceptance Criteria
- [ ] One `decide` call gives one finished span named `decide`, of kind client, with exactly the three attributes.
- [ ] A call that throws gives the error status and the error type.
- [ ] No attribute value of the span contains the state text, a question text, an option text or an answer.
- [ ] An unbootstrapped tracer gives no span and no cost (no-op).

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift` with `InMemoryTracing` and a stub `DecisionModel`: span name, kind, attributes; the throw case; a redaction check with marker strings in the state, questions and options (see `Tests/FoundationModelsRouterTestSupport/RecordingRedactionScan.swift`).
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision