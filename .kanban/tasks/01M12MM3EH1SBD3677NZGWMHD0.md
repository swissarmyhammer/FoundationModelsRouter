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
- Put every span name in one enum: `FoundationModelsRouter.embed` (exists), `.turn`, `.tool`, `.compact`, `.resolve`, `.load`, `.fork`, `.session`.
- Put every span attribute key there also: `router.id`, `model.ref`, `session.id`, `turn.id`, `tool.name`, `slot`, `footprint.bytes`, `budget.bytes`, `tokens.in`, `tokens.out`, and the keys `RoutedEmbedder` uses now.
- Add a helper that returns the applicable tracer: the explicit tracer, or `InstrumentationSystem.tracer` when the explicit tracer is `nil`. `RoutedEmbedder.embed` (Sources/FoundationModelsRouter/RoutedEmbedder.swift:45) has this expression inline today.
- Thread the tracer through the shared session factory, not through one call site. Add a tracer parameter to `makeRoutedSessionActor` (Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:8, constructing at line 40) and pass the profile's tracer at all three call sites: `RoutedLLM.swift:156` (new session), `Recording/SessionTreeRestoration.swift:368` (restored session), and `Session/RoutedSessionActorForking.swift:158` (forked child). If only the first is wired, a forked or restored session holds `nil` and emits nothing to an explicitly injected tracer.
- Change `RoutedEmbedder.embed` to use the shared constants. Do not change its span contract.

Safety rule for all tasks that follow: a span attribute must not contain prompt text, response text, tool arguments, tool output, or embed input text. Write this rule in the doc comment of `RouterTracing`, and prove it with the shared test below rather than leaving it as prose.

## Acceptance Criteria
- [ ] One file holds every span name and every attribute key, including `.load` and `.session`.
- [ ] `RoutedSessionActor` holds the tracer that its `RoutedModel` carries.
- [ ] A forked child and a restored session each hold the same tracer as their parent.
- [ ] `EmbedTracingTests` passes with no change to its assertions.

## Tests
- [ ] Add a test that makes a session from a model with an `InMemoryTracer` and shows the session actor holds that tracer; extend it to a forked child and a restored session.
- [ ] Add the shared no-leak test: after a scripted turn, a tool call, and a fold against an `InMemoryTracer`, walk every recorded span's attribute values and assert none contains the fixture's prompt, response, tool-output, or embed-input strings. Later tracing tasks extend this test rather than restating the rule.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router