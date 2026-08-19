---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0e67wm4yqkf0cnys37bscgk
  text: |-
    Research complete.

    - The runner's `buildProfile(container:cacheDir:recordingsDir:)` and `RealModelHarness.make(model:context:container:cacheDir:recordingsDir:routerId:)` build the same profile. The one difference is the `definitionName` literal: `"compaction-continuity-eval"` against `"real-model-harness"`.
    - No code reads the eval profile's `definitionName`. No eval assertion reads it, and the sidecar is written with `profile: nil`. Thus the harness name is correct for the runner, and the harness needs no new parameter.
    - The runner's private `UnusedEmbeddingContainer` becomes dead after the fold. I will delete it. The harness holds its own copy.
    - `Package.swift` gets one new dependency: `FoundationModelsRouterRealModelSupport` in the `FoundationModelsRouterEvalIntegrationTests` target.
    - Stale doc text to correct: the "Why this is not `RealModelHarness.make`" section in the runner, and the harness header text that says only two suites call it and that the fold "is its own card".
  timestamp: 2026-08-19T23:38:27.332875+00:00
- actor: claude-code
  id: 01m0e6hxnt683hz0g4gr2yk8zg
  text: |-
    ### implement — changed
    - evidence: 3 files — Package.swift (added the `FoundationModelsRouterRealModelSupport` dependency to `FoundationModelsRouterEvalIntegrationTests`), Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionContinuityEvalRealSubjectRunner.swift (deleted `buildProfile` and `UnusedEmbeddingContainer`, call `RealModelHarness.make`; the call-site comment states why the harness `definitionName` is correct: nothing reads the field), Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift (the header and the `definitionName` doc now state that all three suites call the harness). Verification: `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0; `Scripts/swift-test.sh --skip IntegrationTests` green, 1021 tests in 96 suites + 77 tests in 9 suites, exit 0; `swift test --filter CompactionContinuityEvaluationIntegrationTests` green once, 1 test in 28.6 s through the folded harness build. No FM_ROUTER_* env vars, no 30B suite.
    - next: /review
  timestamp: 2026-08-19T23:43:56.090741+00:00
- actor: claude-code
  id: 01m0e6ns56ybehfmre5x5zyvfc
  text: |-
    ### test — green
    - command: `swift build --build-tests -Xswiftc -warnings-as-errors` — build OK, no warnings.
    - command: `Scripts/swift-test.sh --skip IntegrationTests` — 1021 tests in 96 suites passed (1 known issue, the pre-existing BoundedWaitTests item, counts as green), and 77 tests in 9 suites passed. 0 failures, 0 warnings, 0 skipped.
    - Real-model IntegrationTests suites were not run, per instructions. No FM_ROUTER_* variables were used. swift format was not run.
    - next: hand off to review.
  timestamp: 2026-08-19T23:46:02.534463+00:00
position_column: doing
position_ordinal: '8580'
title: Fold CompactionContinuityEvalRealSubjectRunner.buildProfile onto RealModelHarness
---
Found while landing ^cvsh3m9.

`Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionContinuityEvalRealSubjectRunner.swift` keeps its own copy of the profile build in `buildProfile(container:cacheDir:recordingsDir:)`. The copy exists because `RealModelHarness` lived in the integration test target, where only `@testable import` could reach the router's internal initializers, and SwiftPM cannot share source between two leaf test targets.

Task ^cvsh3m9 removed that constraint: the initializers are `package` now, and `RealModelHarness` lives in the plain `FoundationModelsRouterRealModelSupport` target.

## Steps

- [x] Add `FoundationModelsRouterRealModelSupport` to the `FoundationModelsRouterEvalIntegrationTests` dependencies in `Package.swift`.
- [x] Replace `buildProfile` with a call to `RealModelHarness.make(...)`. Keep the runner's own `definitionName` decision on the record, or state why the harness name is correct for it.
- [x] Remove the runner's private `UnusedEmbeddingContainer` copy if the harness makes it dead.
- [x] Update the "Why this is not `RealModelHarness.make`" doc section: after this card, it IS the harness.

## Acceptance Criteria

- [x] The eval runner builds its profile through `RealModelHarness.make`
- [x] `swift build --build-tests -Xswiftc -warnings-as-errors` is clean
- [x] The fast eval tier stays green (`swift test --filter FoundationModelsRouterEvals`) #test-debt