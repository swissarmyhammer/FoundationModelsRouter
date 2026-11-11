---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Use a shared finishedSpans(named:) helper in the integration tests
---
## What
`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift` filters the spans itself in `loadSpans`: `tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.load }`.

The helper `InMemoryTracer.finishedSpans(named:)` is in `Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift`. That file is in the unit test target. The nested `IntegrationTests` package cannot see it.

To use one helper in the two packages, move it to the `FoundationModelsRouterTestSupport` target and make it `public`. That target does not link `InMemoryTracing` now. Thus the move adds the `InMemoryTracing` product to the dependencies of `FoundationModelsRouterTestSupport` in `Package.swift`. Task ^b1nwgra did not do this because it changes the package graph.

## Acceptance Criteria
- [ ] `finishedSpans(named:)` is in `FoundationModelsRouterTestSupport`, and the unit tests and the integration tests use it.
- [ ] `CrossRouterPoolIntegrationTests.swift` does not filter `finishedSpans` by `operationName ==` itself.
- [ ] Run `swift test` once. All tests pass.
- [ ] Run `swift build --package-path IntegrationTests --build-tests` once. The build has no errors and no warnings.