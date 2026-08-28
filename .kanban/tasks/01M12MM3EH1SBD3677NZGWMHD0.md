---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Add shared tracing support and give the session its tracer
---
## What

Make one shared home for the tracing vocabulary, and connect the tracer to the session actor. Today only `RoutedEmbedder.embed` opens a span, with local string literals.

- Create `Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`.
- Put every span name in one enum: `FoundationModelsRouter.embed` (exists), `FoundationModelsRouter.turn`, `FoundationModelsRouter.tool`, `FoundationModelsRouter.compact`, `FoundationModelsRouter.resolve`, `FoundationModelsRouter.fork`.
- Put every span attribute key there also: `router.id`, `model.ref`, `session.id`, `turn.id`, and the keys `RoutedEmbedder` uses now.
- Add a helper that returns the applicable tracer: the explicit tracer, or `InstrumentationSystem.tracer` when the explicit tracer is `nil`. `RoutedEmbedder.embed` (Sources/FoundationModelsRouter/RoutedEmbedder.swift:45) has this expression inline today.
- Pass the tracer from `RoutedModel` into `RoutedSessionActor` in `RoutedLLM.makeSession` (Sources/FoundationModelsRouter/RoutedLLM.swift:55). Keep the resolve-late shape: hold the optional, and read `InstrumentationSystem.tracer` at call time.
- Change `RoutedEmbedder.embed` to use the shared constants. Do not change its span contract.

Safety rule for all tasks that follow: a span attribute must not contain prompt text, response text, or embed input text. Write this rule in the doc comment of `RouterTracing`.

## Acceptance Criteria
- [ ] One file holds every span name and every attribute key.
- [ ] `RoutedSessionActor` holds the tracer that its `RoutedModel` carries.
- [ ] `EmbedTracingTests` passes with no change to its assertions.

## Tests
- [ ] Add a test in `Tests/FoundationModelsRouterTests/` that makes a session from a model with an `InMemoryTracer` and shows the session actor holds that tracer.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router