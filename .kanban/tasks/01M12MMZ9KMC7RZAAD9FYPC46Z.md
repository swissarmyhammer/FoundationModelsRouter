---
assignees:
- claude-code
depends_on:
- 01M12MMJY0BHS8ABZGQKBNBP4A
- 01M1332A3W2HWNRZ24R8SDFY7A
position_column: todo
position_ordinal: '8280'
title: Open one child span for each tool call
---
## What

Wrap each tool invocation in one span, nested in the turn span.

There is no single shared `call` body to instrument. `Sources/FoundationModelsRouter/Hosting/ToolDecorator.swift` holds only a `wrapped` accessor and a `TurnBoundaryTool` default; it has no `call`. `ToolMounting.makeWrapped` (Sources/FoundationModelsRouter/Hosting/ToolMounting.swift:29-79) returns exactly one of three mutually exclusive outermost decorators. Instrument those three:

- `BackgroundToolRunner.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/BackgroundToolRunner.swift:57
- `RunToCompletionRunner.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:57
- `ContextBindingTool.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/ContextBindingTool.swift:51

Do NOT instrument `TokenCappingTool.call(arguments:)` (Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:81). It is a pass-through layer in the same chain, and a span there would double count a capped tool.

- Span name: `FoundationModelsRouter.tool` from `RouterTracing`. Kind: `.internal`.
- Attributes: `tool.name`, `session.id`, the declared run kind (foreground or background), and the outcome.
- The parent must be the turn span; task-local context propagation gives this when the tool call runs in the turn's task. For a background run, the span covers the accept-and-launch step the model sees, not the full background run.
- A tool call that throws must record the error on the span and throw again.
- Do not put tool arguments or tool output in an attribute; the shared no-leak test from the foundation task covers this.

This task depends on the Hosting demotion task because all three decorators construct a `ToolContext` through the initializers that task demotes.

## Acceptance Criteria
- [ ] A turn with two tool calls makes one turn span and two tool spans.
- [ ] Each tool span has the turn span as its parent.
- [ ] A tool that throws keeps its span, with the error recorded.
- [ ] A background tool's span covers the launch step and sets the run kind attribute.
- [ ] A tool with an output token cap configured still produces exactly one tool span, not two.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/ToolTracingTests.swift`. Use `InMemoryTracer` with `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift` and the tool mount fixtures (`ToolMountFixtures.swift`, `ScriptedMarkerTools.swift`).
- [ ] Cover all three decorators: a foreground `String` tool, a background tool, and a non-`String`-output tool.
- [ ] Assert the one-span-per-call rule for a capped tool, using the fixtures from `ToolOutputCappingTests.swift`.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router