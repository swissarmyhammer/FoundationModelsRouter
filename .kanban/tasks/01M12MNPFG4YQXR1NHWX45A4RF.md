---
assignees:
- claude-code
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: todo
position_ordinal: '8480'
title: Open spans for profile resolution and model loads
---
## What

Wrap `Router.resolve` in one span, with one child span for each model load. Resolution is the slowest operation in the library; a trace must show where the time goes.

- Instrument `Router.resolve(profile:reporting:)` (Sources/FoundationModelsRouter/Router.swift:231).
- Outer span name: `FoundationModelsRouter.resolve` from `RouterTracing`. Kind: `.client`. Attributes: `router.id`, the profile definition name, the effective budget in bytes, and, on success, the chosen `model.ref` for each slot.
- Child span name: `FoundationModelsRouter.load`, one for each slot the resolve loads through the `ModelLoader`. Attributes: `model.ref`, the slot name (`standard`, `flash`, `embedding`), and the footprint estimate in bytes. A slot served from the resident pool opens no load span.
- The `Router.tracer ?? InstrumentationSystem.tracer` rule applies, through the `RouterTracing` helper.
- A resolve that throws (`ResolutionFailure`, or a loader error) must record the error on the outer span and throw again.
- Do not change the `ResolutionProgress` reporting; the spans are additional.

## Acceptance Criteria
- [ ] One successful resolve makes one resolve span and one load span for each loaded slot.
- [ ] Each load span has the resolve span as its parent.
- [ ] A resolve that fails keeps its span, with the error recorded.
- [ ] A second resolve that reuses resident models opens no load span for the reused slots.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/ResolveTracingTests.swift`. Use `InMemoryTracer` with the stub loader fixtures from `ResolveTests.swift` and `Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift`.
- [ ] Assert the span names, the parent-child links, the attributes, the reuse case, and the error record.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router