---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: Demote SlotResolution and CandidateReport to package
---
## What

Split out of the Session and Recording demotion task, because this is a separate access-level policy call on a separate subsystem.

`SlotResolution` (Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:89) and `CandidateReport` (line 51) are public only because `RoutedModel.resolution` (Sources/FoundationModelsRouter/LanguageModelProfile.swift:28) is public. No test, example, or tool reads `CandidateReport`, and the type's own fields `verdict` and `ladderAttempts` (SlotResolution.swift:66, 70) are already internal.

- Demote `SlotResolution` and `CandidateReport` to `package`.
- Demote `RoutedModel.resolution` to `package`.
- Demote `RealModelHarness.makeResolution(...)` (Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift:92) to `package`, NOT to `internal`. `FoundationModelsRouterRealModelSupport` is a plain `.target` (Package.swift:208), and `Tests/FoundationModelsRouterTests/RealModelHarnessTests.swift` reaches it through a plain `import` at lines 82 and 106; `internal` does not cross a target boundary and would break the build. No file in the nested `IntegrationTests` package calls `makeResolution`, so `package` is safe.

## Acceptance Criteria
- [ ] The three router symbols and `makeResolution` are `package`.
- [ ] No public signature in the module names `SlotResolution` or `CandidateReport`.

## Tests
- [ ] Run `swift build` and `swift test` at the root. All targets build and all tests pass. `RealModelHarnessTests` compiling is the proof that `makeResolution` kept a wide enough access level.
- [ ] Run `swift build --package-path IntegrationTests`. It builds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup