---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76cv5tnxph5v53ggfjhd2fj
  text: |-
    Research done.
    - The embed span uses `RouterTelemetry.withSpan(SpanName.embed, ofKind: .client, tracer:)` in RoutedEmbedder.swift. Span names have the form `FoundationModelsRouter.<name>`, thus the new span name is `FoundationModelsRouter.decide`.
    - `DecisionSession.init(model:state:)` calls `model.makeExecutor()` one time and `decide` calls `executor.decide(questions, about: state)` only for a batch that is not empty. Thus a batch with no questions gives no span. `prewarm()` calls `executor.prewarm(for:)`.
    - `DecisionSession.model` becomes the traced model. `modelID` and `capabilities` pass through, thus the session checks the same limits.
    - Router passes its `tracer` to each `RoutedModel` in `makeRoutedModel`, the decision handle included. No change in Router.swift is necessary.
    - No test bootstraps `InstrumentationSystem`, thus `RouterTelemetry.tracer(explicit: nil)` is a `NoOpTracer` in the unit tests.
    - Failure test helper: `FinishedInMemorySpan.failureType` in Tests/FoundationModelsRouterTests/Helpers.
  timestamp: 2026-11-11T22:49:48.117386+00:00
- actor: claude-code
  id: 01m76d4pcp6ffnaxjqc9t8q5bw
  text: |-
    Implementation landed.
    - RED: `swift test --filter DecisionTelemetryTests` ran 8 tests; the 5 span tests failed (`spans.count == 1`). The 3 pass-through tests (inner response, prewarm, no-op tracer) passed before the change, as they must.
    - GREEN: the same filter ran 8 tests, all pass.
    - Span name is `FoundationModelsRouter.decide` (the prefix form of the other spans).
    - `TracedDecisionModel` forwards `modelID` and `capabilities`. Its executor holds the traced model and the inner executor. `prewarm(for:)` forwards with no span.
    - New test helper `ThrowingDecisionContainer` (Tests/FoundationModelsRouterTests/Helpers), the same shape as `ThrowingEmbeddingContainer`. New fixture `HandBuiltProfileFixtures.makeDecider(...)`; `makeProfile` uses it.
    - RouterTelemetry DocC says that each new span is held to TelemetryContentSafetyTests. Thus I added a failed decide span case to `TelemetryContentSafetyTests+FailedSpans.swift`: a model that throws a content-bearing error, with content in the state and the question; the capture finds no content.
    - Full suite, one run: 2636 tests in 305 suites passed, plus 41 and 19 in the other targets. No warnings.
  timestamp: 2026-11-11T22:54:59.990127+00:00
- actor: claude-code
  id: 01m76d4sqk3vewh9eqmw6hz0a7
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Tracing/TracedDecisionModel.swift (new), Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Sources/FoundationModelsRouter/RoutedDecider.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift (new), Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift, Tests/FoundationModelsRouterTests/TelemetryContentSafetyTests+FailedSpans.swift, Tests/FoundationModelsRouterTests/TelemetryContentSafetyTests.swift; `swift test` once: 2636 + 41 + 19 tests pass, 0 warnings.
    - next: /review
  timestamp: 2026-11-11T22:55:03.411060+00:00
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: doing
position_ordinal: '80'
title: 'R10: decide span with no state text and no answers'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R10. The model is the `embed` span in `Sources/FoundationModelsRouter/RoutedEmbedder.swift`.

- `Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift`: add `SpanName.decide` (`"decide"` or the name form that the other spans use) and `AttributeKey.decisionQuestionCount = "decision.question_count"`.
- `DecisionSession` is in the Decision package, so the router cannot wrap its methods. New `Sources/FoundationModelsRouter/Tracing/TracedDecisionModel.swift`: a `DecisionModel` that wraps the `decisionModel` of the container. Its executor wraps the `DecisionModelExecutor` of the inner model; each `decide(questions, state)` call runs inside `RouterTelemetry.withSpan(.decide, ofKind: .client, tracer:)` with `router.id`, `model.ref` and `decision.question_count`. `prewarm(for:)` passes through with no span. On a throw, the span gets the error status and the error type only (the existing `withSpan` rule).
- `RoutedDecider.makeSession(state:)` makes the session over the traced model, with the `tracer` and `routerId` of the handle.
- The span holds no state text, no question text, no option text and no answer value. Note this in the DocC, the same as the embed span DocC.

## Acceptance Criteria
- [x] One `decide` call gives one finished span named `decide`, of kind client, with exactly the three attributes.
- [x] A call that throws gives the error status and the error type.
- [x] No attribute value of the span contains the state text, a question text, an option text or an answer.
- [x] An unbootstrapped tracer gives no span and no cost (no-op).

## Tests
- [x] New `Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift` with `InMemoryTracing` and a stub `DecisionModel`: span name, kind, attributes; the throw case; a redaction check with marker strings in the state, questions and options (see `Tests/FoundationModelsRouterTestSupport/RecordingRedactionScan.swift`).
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision