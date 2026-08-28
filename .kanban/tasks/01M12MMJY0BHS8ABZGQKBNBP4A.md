---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14evjyf2jy5jfmdkrdt61rk
  text: |-
    Picked up. Research notes:

    - `runTurn` is the one chokepoint. Callers: `generate(grammar:prompt:onEvent:_:)` (four call sites, all in RoutedSessionActorGeneration.swift — `respond` twice, `streamGenerating`, `streamEventsGenerating`) and `runDispatchedTurn` (dispatch and delivery turns).
    - `RouterTracing.AttributeKey` has NO key for the turn entry point that the card requires. The vocabulary enum is the one home for a span name or key, so the entry point gets a new key there rather than a bare literal at the call site.
    - Token counts: after a good turn `finishTurn` sets `usageState = .measured(input:output:)`. `ContextUsageState.measuredTokens` only gives the sum, so the span reads the case directly for the two separate values.
    - `SpanContentSafetyTests` names no span, so it holds the turn span to the no-leak rule the moment the span lands, with no edit to that file (the file says so itself).
    - swift-distributed-tracing 1.4.1 carries an `isolation: isolated (any Actor)? = #isolation` overload of `withSpan`, so the span closure runs in the actor's isolation.
  timestamp: 2026-08-28T15:12:18.895768+00:00
- actor: claude-code
  id: 01m14g07ard01bv20ff51q6gnf
  text: |-
    Implementation landed, TDD order.

    RED: wrote Tests/FoundationModelsRouterTests/TurnTracingTests.swift first. 5 of the 6 cases failed on `spans.count == 1 -> 0`, and the no-tracer control passed, which is the correct shape of a first failure.

    GREEN:
    - `RouterTracing`: took the `// periphery:ignore` markers off `SpanName.turn`, `AttributeKey.sessionId`, `AttributeKey.turnId`, `AttributeKey.tokensIn` and `AttributeKey.tokensOut`, because this card gives each of them a caller.
    - `RouterTracing`: added `AttributeKey.turnEntryPoint` (`turn.entry_point`) and the `TurnEntryPoint` value enum (`respond`, `stream`, `dispatch`). The card names the entry-point attribute, and the vocabulary enum had no key for it. A new key in that one home is the shape the file states; a bare literal at the call site is not.
    - `runTurn` is now the span wrapper. The work it used to hold moved to `runTurnWork`, unchanged. `recordMeasuredTokens(on:)` writes `tokens.in`/`tokens.out` from `usageState` after a good turn, and writes nothing when the backend could not meter.
    - `generate(...)` takes `entryPoint` with no default, so each of its four call sites states the surface. `runDispatchedTurn` passes `.dispatch`.
    - `RoutedSession` doc comments: `respond(to:maxTokens:)` states the whole span contract as a table, and `streamResponse`, `streamEvents` and `dispatchNextPrompt` refer to it and name their own `turn.entry_point` value.

    Decisions worth recording:
    - `SpanContentSafetyTests` was NOT edited. Its own header states that it names no span, so a new span is held to the no-leak rule the moment it lands, "with no edit to this file". That suite drives a turn through a tracer-carrying fixture, so the turn span is inside what it measures now. A duplicate no-leak case in TurnTracingTests would restate the rule instead of using it.
    - `TurnTracingTests` builds its own session over one shared `StubSessionBackend`, not `ScriptedSessionFixture`: the token-count case needs `StubSessionBackend.usageIncrement` for deterministic counts, and the failure case needs to flip `shouldThrow` on the live backend after the session exists. The scripted container vends the production backend, which meters whatever the SDK reports.

    Flaky note for the next agent: a first full `swift test` run reported `GenerationStallDiagnosticTests` AND `HumanWaitGateTests` ("a human wait overlapping a turn it is not part of leaves the gate at exactly one permit") failing at BoundedWait.swift:114. Both depend on a wall clock. A re-run of those two suites passed, and two later full runs passed clean. Neither is related to the span.
  timestamp: 2026-08-28T15:32:19.416732+00:00
- actor: claude-code
  id: 01m14g0fqww9pmp942xy36pxqc
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Tracing/RouterTracing.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Tests/FoundationModelsRouterTests/TurnTracingTests.swift (new). `swift build` clean. `swift test` 1078 tests in 111 suites passed with the 2 known issues, plus 83 eval tests — 1072/110 before, so +6 tests and +1 suite, which is exactly the new suite. `swift build --package-path IntegrationTests --build-tests` Build complete.
    - next: ready for /review
  timestamp: 2026-08-28T15:32:28.028644+00:00
- actor: claude-code
  id: 01m14gaxc93av7bqpsydjk1kkf
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit e05cd55), 5 files reviewed, 7 validators attempted, 0 failed. counts: 0 findings, 0 confirmed, 0 refuted. All acceptance and test items in the description are checked, and there is no earlier `## Review Findings` section.
    - The two decisions of the implementer were examined:
      1. `TurnEntryPoint` value enum in `RouterTracing` — CORRECT. The header of the file makes the vocabulary "one home for the vocabulary, so a name is written once and read everywhere", and it says a name there is part of the observable surface of the router. A string literal at the call site breaks that rule. The enum also agrees with the `SpanName` and `AttributeKey` pattern next to it, and it gives the compiler the three permitted values. `generate(...)` takes `entryPoint` with no default value, so each of the four call sites must state its surface.
      2. `SpanContentSafetyTests` left untouched — the claim is TRUE, and it is now measured, not only stated. Proof: the suite makes its fixture with `tracer: tracer` (SpanContentSafetyTests.swift:64); `ScriptedSessionFixture.make` gives that tracer to the `Router` (ScriptedSessionFixture.swift:79), and each handle of the resolved profile carries it, so `RouterTracing.tracer(explicit: tracer)` in `runTurn` resolves to the `InMemoryTracer`. The suite then drives real turns — `respond(to:)` at SpanContentSafetyTests.swift:70, more turns at :76, a fold at :80 — and `renderedAttributes` (:39-47) reads every attribute of every span in `finishedSpans` with no filter by span name. The needles at :87 hold the prompt, the answer, the tool output and the embed input, and `#expect(!rendered.isEmpty)` at :92 stops a suite that measures nothing from passing in silence. The new turn span is therefore inside what the suite measures. No finding.
    - The span wrapper itself is a pure wrapper: `runTurnWork` holds the moved work unchanged, `recordMeasuredTokens(on:)` writes `tokens.in`/`tokens.out` only for a `.measured` usage state and writes nothing for a turn the backend could not meter, which is better than a guess. `withSpan` records a thrown error and raises it again.
    - next: none. Task moved to `done`.
  timestamp: 2026-08-28T15:38:09.673251+00:00
- actor: claude-code
  id: 01m14gbxkhx6fya69ycyd7611j
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files; RouterTracing.swift, RoutedSessionActorTurnExecution.swift, RoutedSessionActorGeneration.swift, RoutedSession.swift, and the new TurnTracingTests.swift
    - test: green — swift test, 1078 tests in 111 suites passed with 2 known issues, plus 83 eval tests. The baseline was 1072 in 110 suites, so the difference is exactly the new suite. `swift build --package-path IntegrationTests --build-tests` also completed.
    - commit: e05cd55
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - next: none — the task is in done

    The reviewer made a good observation about the two test suites together. `SpanContentSafetyTests` proves that no attribute carries the caller's content, but it cannot prove a turn span reached the tracer: if the turn span were dropped, that suite alone would still pass. `TurnTracingTests` closes the gap, because each case demands one finished span with the matching operation name.

    Two flaky wall-clock tests were seen again, both at BoundedWait.swift:114: `GenerationStallDiagnosticTests` and `HumanWaitGateTests`. Each passed on a re-run, and two later full runs were clean.
  timestamp: 2026-08-28T15:38:42.673242+00:00
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: done
position_ordinal: ffff9780
title: Open one span for each generation turn
---
## What

Wrap each generation turn in one span, at the one point all turn entries flow through.

- Instrument `RoutedSessionActor.runTurn` (Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift). Every surface uses this path: `respond(to:maxTokens:)`, `streamResponse(to:maxTokens:)`, `streamEvents(to:maxTokens:)`, and `dispatchNextPrompt()`. The delivery-turn path `runDispatchedTurn` also reaches it, so one span here covers all of them.
- Span name: `FoundationModelsRouter.turn` from `RouterTracing`. Kind: `.client`.
- Attributes: `router.id`, `session.id`, `model.ref`, `turn.id`, and the turn entry point (`respond`, `stream`, or `dispatch`).
- After a good turn, set the measured token counts from the turn's usage snapshot (see `usageState` and Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift) as the `tokens.in` and `tokens.out` attributes.
- A turn that throws must record the error on the span and throw again. `withSpan` gives this. A cancelled turn records `CancellationError`.
- Do not put prompt text or response text in an attribute; the shared no-leak test from the foundation task covers this.
- Extend the doc comments on the `RoutedSession` protocol methods to state the span contract, as `RoutedEmbedder.embed` does.

## Acceptance Criteria
- [x] One `respond` call makes exactly one turn span with the named attributes.
- [x] One streamed turn and one dispatched turn each make one turn span.
- [x] A failed turn keeps its span, with the error recorded.
- [x] With `InstrumentationSystem` left unbootstrapped and no explicit tracer, the existing turn suites pass unchanged.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/TurnTracingTests.swift`. Use `InMemoryTracer` and the scripted fixtures (`Tests/FoundationModelsRouterTests/Helpers/ScriptedSessionFixture.swift`, `StubSessionBackend.swift`). Model the suite on `EmbedTracingTests.swift`.
- [x] Assert the span name, kind, attributes, token attributes, and the error record for a turn that throws.
- [x] Add one case that runs a turn with no tracer injected and no backend bootstrapped, and asserts the turn returns its normal response.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router