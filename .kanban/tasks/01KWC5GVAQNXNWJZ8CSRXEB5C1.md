---
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
position_column: todo
position_ordinal: 8c80
title: 'Tool integration: shared-profile constructor pattern (milestone 6)'
---
## What
Validate the plan's core "built early and shared" goal: tools take the router (or a model it vends) in their constructors so many tools reuse a small set of resident models. Plan "Goal" + milestone 6.

- `Sources/FoundationModelsRouter/` — add a small, real example tool to exercise the pattern, e.g. `SummarizeTool(model: RoutedLLM)` and an `EmbedTool(model: RoutedEmbedder)`, each holding the injected handle and calling `makeSession`/`embed`.
- Document the pattern (doc comment) on `RoutedLLM`/`RoutedEmbedder`: pass the slot handle into tool constructors; do not re-resolve per tool.
- Demonstrate that multiple tools constructed from the same resolved `LanguageModelProfile` share the identical resident model instance (no extra load).

## Acceptance Criteria
- [ ] Two tools built from `profile.flash` reference the same underlying resident model (assert identity/footprint accounting — no second load occurs; verify via the loader spy from milestone 5).
- [ ] A tool runs a generation/embedding through its injected handle and goes through the recorded chokepoint.
- [ ] Constructing tools does not change the active-profile residency (still one profile resident).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift` (Swift Testing) with the stub loader/recorder: two tools share one resident model (loader invoked once for the slot); a tool's call records a turn; residency unchanged.
- [ ] Run `swift test --filter ToolIntegrationTests` — all pass.

## Workflow
- Use `/tdd` — write the failing shared-instance + recorded-call tests first.