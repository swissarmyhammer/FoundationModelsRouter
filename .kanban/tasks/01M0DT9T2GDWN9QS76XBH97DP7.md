---
assignees:
- claude-code
position_column: todo
position_ordinal: 9c80
title: Fold CompactionContinuityEvalRealSubjectRunner.buildProfile onto RealModelHarness
---
Found while landing ^cvsh3m9.

`Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionContinuityEvalRealSubjectRunner.swift` keeps its own copy of the profile build in `buildProfile(container:cacheDir:recordingsDir:)`. The copy exists because `RealModelHarness` lived in the integration test target, where only `@testable import` could reach the router's internal initializers, and SwiftPM cannot share source between two leaf test targets.

Task ^cvsh3m9 removed that constraint: the initializers are `package` now, and `RealModelHarness` lives in the plain `FoundationModelsRouterRealModelSupport` target.

## Steps

- Add `FoundationModelsRouterRealModelSupport` to the `FoundationModelsRouterEvalIntegrationTests` dependencies in `Package.swift`.
- Replace `buildProfile` with a call to `RealModelHarness.make(...)`. Keep the runner's own `definitionName` decision on the record, or state why the harness name is correct for it.
- Remove the runner's private `UnusedEmbeddingContainer` copy if the harness makes it dead.
- Update the "Why this is not `RealModelHarness.make`" doc section: after this card, it IS the harness.

## Acceptance Criteria

- [ ] The eval runner builds its profile through `RealModelHarness.make`
- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` is clean
- [ ] The fast eval tier stays green (`swift test --filter FoundationModelsRouterEvals`)
#test-debt