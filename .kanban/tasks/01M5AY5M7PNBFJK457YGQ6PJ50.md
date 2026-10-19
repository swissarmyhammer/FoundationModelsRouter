---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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
- [ ] No test file holds a private copy of the shared `BasicLLMContainer` behavior.
- [ ] Each suite in the list keeps its test behavior.
- [ ] `swift build --build-tests` gives no new warning.

## Tests
- [ ] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass, and each changed suite reports a non-zero test count.
