---
assignees:
- claude-code
position_column: todo
position_ordinal: ae80
title: 'OTel router E: use the Extras tool span name FoundationModelsExtras.tool in the router tests and docs'
---
## What
User decision (2026-09-28, relayed by the swissarmyhammer session): the tool span name changes from `FoundationModelsRouter.tool` to `FoundationModelsExtras.tool`. The tool span is opened by the Extras tool hosting (the router uses it since task ^nxke7g0), so the change is in Extras.

Blocked by Extras task 01M3MN9PAWGYCD0948TC91JNMP (^c91jnmp, Extras OTel D: the Extras telemetry vocabulary and the tool span rename). It must be on Extras `main`. Update the router's `Package.resolved` (ignored by git) with `swift package update FoundationModelsExtras`, and set `IntegrationTests/Package.resolved` to the same revision.

- `Tests/FoundationModelsRouterTests/ToolTracingTests.swift:31`: the test constant for the tool span name. If the Extras vocabulary is public, read the name from it and do not repeat the string.
- `Sources/FoundationModelsRouter/Tracing/RouterTracing.swift:40` (or `RouterTelemetry.swift`, if OTel router task A 01M3MND1G818WNMRPDFRAG2E91 is done first) and `Sources/FoundationModelsRouter/RoutedLLM.swift:250`: doc comments that name the tool span. Change them to the Extras name.
- Search the whole repo (Sources, Tests, IntegrationTests, docs, README, DocC) for `FoundationModelsRouter.tool` and change each reference.

## Acceptance Criteria
- [ ] No reference to `FoundationModelsRouter.tool` is left in the repo.
- [ ] The tool tracing tests check the span name `FoundationModelsExtras.tool`.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] `ToolTracingTests` passes with the new name.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo