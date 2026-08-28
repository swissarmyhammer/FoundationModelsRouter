---
assignees:
- claude-code
depends_on:
- 01M12MMJY0BHS8ABZGQKBNBP4A
position_column: todo
position_ordinal: '8280'
title: Open one child span for each tool call
---
## What

Wrap each tool invocation in one span, nested in the turn span.

- Instrument the shared decorator body in Sources/FoundationModelsRouter/Hosting/ToolDecorator.swift, where every mounted tool's `call` flows through. All decorated tools must go through the one instrumented point; add the span at that chokepoint only, not per decorator.
- Span name: `FoundationModelsRouter.tool` from `RouterTracing`. Kind: `.internal`.
- Attributes: `tool.name`, `session.id`, the declared run kind (foreground or background; see Sources/FoundationModelsRouter/Hosting/BackgroundTool.swift and ToolInvocationRecord), and the outcome.
- The parent must be the turn span. Task-local context propagation from `swift-distributed-tracing` gives this when the tool call runs in the turn's task. For a background run, the span covers the accept-and-launch step the model sees, not the full background run.
- A tool call that throws must record the error on the span and throw again.
- Do not put tool arguments or tool output text in an attribute.

## Acceptance Criteria
- [ ] A turn with two tool calls makes one turn span and two tool spans.
- [ ] Each tool span has the turn span as its parent.
- [ ] A tool that throws keeps its span, with the error recorded.
- [ ] A background tool's span covers the launch step and sets the run kind attribute.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/ToolTracingTests.swift`. Use `InMemoryTracer` with `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift` and the tool mount fixtures (`ToolMountFixtures.swift`, `ScriptedMarkerTools.swift`).
- [ ] Assert the span name, the parent-child link to the turn span, the attributes, and the error record.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router