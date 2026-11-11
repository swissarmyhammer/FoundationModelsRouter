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
- actor: claude-code
  id: 01m76dcjyqja8pfaj2v71cagdn
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (95de25a0); 3 findings, 3 confirmed, 0 refuted — Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:208, Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:229, Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift:23
    - next: implement the 3 open items in the "Review Findings (2026-11-11 17:56)" section, then review again.
  timestamp: 2026-11-11T22:59:18.615008+00:00
- actor: claude-code
  id: 01m76dd7av8da1b2dt2hns924e
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — Tracing/TracedDecisionModel.swift (new), Tracing/RouterTelemetry.swift, RoutedDecider.swift, LanguageModelProfile.swift (DocC), 5 test files
    - test: green — swift test, 2636 + 41 + 19 passed, 0 skipped
    - commit: 95de25a0 (message amended to the correct span name FoundationModelsRouter.decide)
    - review: findings — Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:208, Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:229, Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift:23
  timestamp: 2026-11-11T22:59:39.483394+00:00
- actor: claude-code
  id: 01m76dkfpyr22frv91hmmr647j
  text: |-
    Review findings of 2026-11-11 17:56 are done.
    - Finding 1 (reuse): new `InMemoryTracer.finishedSpans(named:)` in Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift. An extension method, the same as the existing `finishedSubmissionSpans` extension in StubBackendSessionFixture.swift. The decide tests call it directly; `finishedDecideSpans` is deleted. `finishedEmbedSpans`, `finishedSessionSpans` and `finishedSubmissionSpans` call it. Other test files still copy the filter; new task records them.
    - Finding 2 (ReplaceForEachWithForLoop): `SpanAttributes` is not a `Sequence`. It has only `forEach`, thus a for-in loop does not compile on it. The fix removes the walk: the three-attribute test compares `span.attributes` with a `SpanAttributes` literal (the type is Equatable and ExpressibleByDictionaryLiteral). The redaction test reads each name of `attributeNames` with `get` and requires that the count of values equals `attributes.count`, thus it reads every attribute. No other `.forEach` is in the files of 95de25a0. `EmbedTracingTests.swift` has one older `.forEach` that this work does not touch.
    - Finding 3 (reuse): Helpers/ThrowingDecisionContainer.swift is deleted. The tests use the internal `UnavailableDecisionContainer(ref:error:)`. No access change was necessary: the container is internal; its model and executor stay private.
    - Full suite, one run: 2636 tests in 305 suites, 41 in 23, 19 in 3, all pass. One build-system line `warning: missing creator for mutated node` for the mlx-swift_Cmlx bundle; no compiler warning.
  timestamp: 2026-11-11T23:03:04.670494+00:00
- actor: claude-code
  id: 01m76dkq7xs0jf9jgd19g0p5g4
  text: |-
    ### implement — changed
    - evidence: 8 files — Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift (new), Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift (deleted), Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift, Tests/FoundationModelsRouterTests/EmbedTracingTests.swift, Tests/FoundationModelsRouterTests/SessionCreationTracingTests.swift, Tests/FoundationModelsRouterTests/Helpers/StubBackendSessionFixture.swift, Tests/FoundationModelsRouterTests/TelemetryContentSafetyTests+FailedSpans.swift; `swift test` once: 2636 + 41 + 19 tests pass. New task 01M76DKA3PC57HS7BE1B1NWGRA for the other filter copies.
    - next: /review
  timestamp: 2026-11-11T23:03:12.381286+00:00
- actor: claude-code
  id: 01m76drgg8wcxrwhcw4v16ctxk
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (79d596d8): 0 findings, 0 confirmed, 1 refuted, 7 files reviewed. All 3 items of the prior Review Findings section are checked. Five tool rules declined Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift because this commit deleted that file.
    - next: none. The task moved to done.
  timestamp: 2026-11-11T23:05:49.320862+00:00
- actor: claude-code
  id: 01m76drzk9y87akagfc6b3wqdy
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — Helpers/InMemoryTracer+FinishedSpans.swift (new), ThrowingDecisionContainer.swift (deleted), DecisionTelemetryTests.swift, EmbedTracingTests.swift, SessionCreationTracingTests.swift, StubBackendSessionFixture.swift, TelemetryContentSafetyTests+FailedSpans.swift
    - test: green — swift test, 2636 + 41 + 19 passed, 0 skipped
    - commit: 79d596d8
    - review: clean — 0 findings
  timestamp: 2026-11-11T23:06:04.777053+00:00
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: done
position_ordinal: ffffffffff8380
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

## Review Findings (2026-11-11 17:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:208` `reuse/reuse` — `finishedDecideSpans(reportedTo:)` re-implements the span filter of `EmbedTracingTests.finishedEmbedSpans`. Both filter a tracer's finished spans by one operation name. The new helper copies that shape for a second span name rather than extending the existing helper or a shared one. Two copies of the same filter can drift apart. Move the filter into one shared test helper that takes the span name as a parameter, such as `finishedSpans(named:reportedTo:)`. Have `finishedDecideSpans`, `finishedEmbedSpans` and `finishedSessionSpans` call it, or have the decide tests call it directly.
- [x] `Tests/FoundationModelsRouterTests/DecisionTelemetryTests.swift:229` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
- [x] `Tests/FoundationModelsRouterTests/Helpers/ThrowingDecisionContainer.swift:23` `reuse/reuse` — The test helper `ThrowingDecisionContainer` re-implements the private `Model` and `Executor` pair that already exists in production as `UnavailableDecisionContainer`, `UnavailableDecisionModel` and `UnavailableDecisionExecutor`. Each one holds one error and throws it from every `decide` call, and answers no question. The copy also diverges only in the `modelID` text, which the throwing path never reads. Keeping two copies of the same throw-always decision model means a fix to one does not reach the other. Remove the `Model` and `Executor` types from ThrowingDecisionContainer.swift. Have the failure tests build `UnavailableDecisionContainer(ref: ref, error: failure)` instead, and keep only the test-specific wrapper if it is still needed. If the production type must stay private, widen it to `internal` for tests rather than copying it.
