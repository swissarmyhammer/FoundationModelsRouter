---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5b7pwqs33vnsx4n6g16em41
  text: |-
    Research:
    - `StubSessionBackend.init` has `responseText: String = "stub response"`. Thus `StubSessionBackend()` is equal to `StubSessionBackend(responseText: "stub response")`. The copies in BackgroundRunTranscriptTests and SessionConfigurationTests are equal to the shared type.
    - `PlainTranscriptStubContainer` gives `tokenCounter` = `CharacterTokenCounter()` in its extension. The stored `tokenCounter` in the SessionRestorationTests copy is the same counter. That copy is equal to the shared type too.
    - No test casts to `BasicLLMContainer` or compares it by identity. Thus a `final class` copy and the shared `struct` give the same behavior.
    - PendingEventInjectionTests needs a configurable `responseText`. SessionMailQueueTests needs `responseText` and `usageIncrement`.
    Design decision: the shared type accepts `responseText` and `usageIncrement` in an init with defaults ("stub response", nil). The default behavior does not change. The static constant gets the name `defaultResponseText`, because the instance property now has the name `responseText`. Nothing outside the fixture reads the static constant. All 8 private copies go.
  timestamp: 2026-10-19T23:24:53.369591+00:00
- actor: claude-code
  id: 01m5b80649j3ta94hrbq94nq5a
  text: |-
    Implementation done.
    - The shared `BasicLLMContainer` (RouterTestFixtures.swift) now has `init(responseText: String = Self.defaultResponseText, usageIncrement: (input: Int, output: Int)? = nil)`. `makeSession` gives `StubSessionBackend(responseText:usageIncrement:)`. The static constant is now `defaultResponseText` ("stub response"), because the instance property has the name `responseText`. No other file read the old static name.
    - I removed all 8 private copies. 5 of them were equal to the old shared type (see the research comment). PendingEventInjectionTests and SessionMailQueueTests now give their values to the shared init. Their call sites did not change.
    - The `makeSession` default in PendingEventInjectionTests now points to `BasicLLMContainer.defaultResponseText`, not a second "stub response" literal. The `#expect(text == "stub response")` checks did not change.
    - I removed the empty `// MARK: - Stub container` lines in PlanRestorationTests, BackgroundRunTranscriptTests and SessionConfigurationTests.
    - I did not change ARCHITECTURE.md. This is test support only.
  timestamp: 2026-10-19T23:29:57.897271+00:00
- actor: claude-code
  id: 01m5b809j24y75a3yk377h15n9
  text: |-
    ### implement — changed
    - evidence: 9 files: Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, PlanRestorationTests.swift, SessionTreeRestorationLostRunTests.swift, ElicitationRoutingTests.swift, BackgroundRunTranscriptTests.swift, SessionConfigurationTests.swift, SessionRestorationTests.swift, PendingEventInjectionTests.swift, SessionMailQueueTests.swift. `swift build --build-tests`: the test target compiled again, with no compiler warnings. The one `missing creator for mutated node` line is a build-system message about the MLX bundle. `swift test`: 1916 tests in 237 suites passed (9 known issues that were there before), and 26 + 19 tests in the other targets passed. `swift test --skip-build --filter 'FoundationModelsRouterTests\.(8 edited suites|HookLineageTests)/'`: 110 tests in 9 suites passed.
    - next: /review
  timestamp: 2026-10-19T23:30:01.410230+00:00
- actor: claude-code
  id: 01m5b82kjsks6jh5a6qg0y0eeb
  text: |-
    ### test — green
    - evidence: I touched the 9 changed test files. I ran `swift test` one time at the repo root. Build complete, 0 compile errors. Swift Testing: 1916 tests in 237 suites passed, 9 known issues (these are `withKnownIssue` cases that were already in the suite). Two more runs passed: 26 tests in 14 suites, and 19 tests in 3 suites. 0 failures, 0 skipped.
    - warnings: only the known warning "missing creator for mutated node" (mlx). No new warning. I did not run `swift format`. I did not change pins. I did not commit.
    - next: review
  timestamp: 2026-10-19T23:31:17.209815+00:00
position_column: doing
position_ordinal: '80'
title: Use the shared BasicLLMContainer in the test suites that hold a private copy
---
## Context
Task ^qstwwj1 added one shared `BasicLLMContainer` to `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift`. It is a `PlainTranscriptStubContainer`. Each session that it makes is a `StubSessionBackend(responseText: BasicLLMContainer.responseText)`, and `responseText` is `"stub response"`. `HookLineageTests` uses the shared type now.

Other suites still hold a private nested copy with the same name. A nested copy hides the shared type in its suite. The copies can drift out of sync.

## What
Remove each private copy that is equal to the shared type, and use the shared type. Where a copy has a different behavior, keep the different behavior, but do not keep a copy of the shared behavior. Give the copy a name that tells its behavior, or make the shared type accept the different value, whichever is the better design.

Copies that are equal to the shared type (a `StubSessionBackend(responseText: "stub response")`):
- `Tests/FoundationModelsRouterTests/PlanRestorationTests.swift`
- `Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift` (a `final class`)
- `Tests/FoundationModelsRouterTests/ElicitationRoutingTests.swift` (a `final class`)

Copies with a different behavior (examine each one before you change it):
- `Tests/FoundationModelsRouterTests/BackgroundRunTranscriptTests.swift` and `Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift`: `StubSessionBackend()` with no response text.
- `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift`: has a `tokenCounter` (`CharacterTokenCounter`).
- `Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift`: a `final class` with `init(responseText:)`.
- `Tests/FoundationModelsRouterTests/SessionMailQueueTests.swift`: a `final class` with `responseText` and `usageIncrement`.

## Acceptance Criteria
- [x] No test file holds a private copy of the shared `BasicLLMContainer` behavior.
- [x] Each suite in the list keeps its test behavior.
- [x] `swift build --build-tests` gives no new warning.

## Tests
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass, and each changed suite reports a non-zero test count.
