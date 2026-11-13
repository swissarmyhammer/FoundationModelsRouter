---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78j6k6x9a6pb59dez22kyq6
  text: 'Research: only `CrossRouterPoolIntegrationTests.loadSpans` filters finished spans by `operationName ==` in `IntegrationTests/`. The integration test target links `InMemoryTracing` and imports `FoundationModelsRouterTestSupport` already. The package has no `MemberImportVisibility` setting, thus a public extension member is visible in a file with no import of its module. Each unit test file that calls `finishedSpans(named:)` now imports `FoundationModelsRouterTestSupport` to show the dependency. The helper moved with `git mv` to `Tests/FoundationModelsRouterTestSupport/InMemoryTracer+FinishedSpans.swift`.'
  timestamp: 2026-11-12T19:01:54.013664+00:00
- actor: claude-code
  id: 01m794p1hg69wb9xycq267n7bp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 15 files (helper moved with git mv to Tests/FoundationModelsRouterTestSupport/InMemoryTracer+FinishedSpans.swift and made public; TestSupport links InMemoryTracing; CrossRouterPoolIntegrationTests.loadSpans uses finishedSpans(named:)).
    - test: green — `swift test`: 2638 tests in 305 suites, 41 in 23, 19 in 3 passed; 0 warnings. `swift build --package-path IntegrationTests --build-tests`: exit 0, 0 errors, 0 warnings.
    - commit: 865a7188
    - review: clean — review sha HEAD~1..HEAD, 0 findings.
    - note: the worktree agent could not build IntegrationTests in a copy (submodule fetch of llama-cpp-swift failed: curl 56). The change was applied and verified in the main checkout.
  timestamp: 2026-11-13T00:24:54.576019+00:00
position_column: done
position_ordinal: ffffffffff8980
title: Use a shared finishedSpans(named:) helper in the integration tests
---
## What
`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift` filters the spans itself in `loadSpans`: `tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.load }`.

The helper `InMemoryTracer.finishedSpans(named:)` is in `Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift`. That file is in the unit test target. The nested `IntegrationTests` package cannot see it.

To use one helper in the two packages, move it to the `FoundationModelsRouterTestSupport` target and make it `public`. That target does not link `InMemoryTracing` now. Thus the move adds the `InMemoryTracing` product to the dependencies of `FoundationModelsRouterTestSupport` in `Package.swift`. Task ^b1nwgra did not do this because it changes the package graph.

## Acceptance Criteria
- [x] `finishedSpans(named:)` is in `FoundationModelsRouterTestSupport`, and the unit tests and the integration tests use it.
- [x] `CrossRouterPoolIntegrationTests.swift` does not filter `finishedSpans` by `operationName ==` itself.
- [x] Run `swift test` once. All tests pass.
- [x] Run `swift build --package-path IntegrationTests --build-tests` once. The build has no errors and no warnings.