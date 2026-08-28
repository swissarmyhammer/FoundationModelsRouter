---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1389he5n9gkndj72gsv4j9b
  text: |-
    Picked up. Research done before any edit.

    Facts found:
    - `RoutedModel.tracer` is `let tracer: (any Tracer)?` in `Sources/FoundationModelsRouter/LanguageModelProfile.swift`. `Router.tracer` hands it to every vended handle.
    - The three `makeRoutedSessionActor` call sites are confirmed: `RoutedLLM.swift` (`makeSession(grammar:...)`, has `self.tracer`), `Recording/SessionTreeRestoration.swift` (`restoreSessionTree`, has `routedLLM.tracer`), `Session/RoutedSessionActorForking.swift` (`fork(workingDirectory:)`, an extension on the actor, so it forwards its own stored `tracer`).
    - `InMemoryTracer` is a **struct** over shared locked storage, not a class. So `===` cannot prove "the session holds that tracer". The wiring test therefore opens a probe span through the session's stored tracer and looks for it in the fixture tracer's `finishedSpans`; two copies of one `InMemoryTracer` share one span log, so a probe that lands proves the wiring.
    - Test-only reach onto the actor follows the existing `Tests/.../Helpers/SessionPlumbingAccess.swift` pattern (`outbox`, `mailbox` accessors that force-cast `RoutedSession` to `RoutedSessionActor`).
    - The scripted turn plus tool call already has a fixture: `Helpers/ScriptedSessionFixture.swift` over `ScriptedToolCallingModel` and `MarkerEmittingTool`. It does not take a tracer and does not expose the profile, so it needs both added.
    - Restore needs two routers that share one id and one `recordingsDir`, as in `SessionTreeRestorationToolWiringTests`.
    - Most span names and attribute keys the card lists have no consumer until the five dependent cards land. They carry `// periphery:ignore` with a note, the convention this repository already uses (`Router.swift`, `Resolution/JointFit.swift`).
  timestamp: 2026-08-28T03:58:21.637243+00:00
position_column: doing
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