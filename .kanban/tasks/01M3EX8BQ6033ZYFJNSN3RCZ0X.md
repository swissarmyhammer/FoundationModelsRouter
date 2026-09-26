---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fgfhwtrhny1p838g8f3tgf
  text: |-
    ### Baseline (before the change)

    - `swift test` (full suite, no filter): 1458 + 17 + 19 = 1494 tests, all pass.
    - Periphery 3.8.0 on a new scratch path (`swift build --build-tests --scratch-path <new>`, then `periphery scan --skip-build --index-store-path <new>/out --retain-public --relative-results`): 1422 findings in total, 54 in the files of this package (`Sources/`, `Tests/`, `Examples/`, `Tools/`), 47 in `Tests/`.
    - ^qhf29tg and ^rbm6jtz removed no item of this task. Each item of items 1 to 3 was still in the Periphery output.
    - The current output has 5 findings in `Tests/` that the task does not name:
      - `import FoundationModelsRouterTestSupport` in `SummarizerPromptCacheTests.swift`. It is dead. I removed it with the item 3 group.
      - Unused parameter `arguments` in `Helpers/ToolMountFixtures.swift` (two `timeout(from:)` conformances of `BackgroundTool`), and unused parameters `ref` and `context` in `JointFitTests.swift` (two closures that the tests give to `JointFit.resolve`). The signatures must stay, so I changed only the internal names to `_`. The call sites do not change. (The same style is in `RejectingLanguageModel.respond(to:model _:streamingInto:)`.)

    ### Map of each item to the current result

    Item 1 (still dead, removed): `SessionEventLog.contains(_:)`, `TranscriptFixtures.makeAnswerEntryLists(_:toolOutputText:)`.

    Item 2:
    - Still dead, removed: `lastBackend` (AutoCompactionTests, ToolOutputCappingTests; the doc comment of `ToolCapturingLLMContainer` now names `lastTools` only), `profile` (RepetitionStopRestoreTests), `recordingProfile` and `recorder` (SessionRestorationTests), `text` (MessageQueuePublicSurfaceTests).
    - Not dead, kept with a reason comment and `// periphery:ignore`:
      - `FailingSummarizer.Failure.name`, `Abandoned.failure`, `Abandoned.tier`: the synthesized `Equatable` conformance reads them. `OneCallCompactionTierTests` compares whole values with `==` and `#expect(throws: Failure(name:))`. If they are removed, the comparisons are always true.
      - `FileChangeSetProbe.changes`, `Change.path`, `Change.kind`: `Decodable` sets them from JSON and the synthesized `==` reads them in `attachedRecordsDecodeBackUnchanged`.
      - `UnscriptedCall.callIndex`: a test failure shows the thrown error with `String(describing:)`, which reads the field by reflection. It is the only data that tells which call the script did not name.
    - Lifetime check (the CAUTION of the task):
      - `StoppedSession.profile`: `RoutedSessionActor` holds its `profile` strongly (`nonisolated let profile`), so `session` keeps the profile alive. The field did no work. Removed.
      - `Recording.recordingProfile`: both routers use `StubModelLoader`, which has the no-op `evict(container:)` of the protocol, and each router has its own `ModelPool()`. A release of the recording profile does nothing that a test can see. Removed.
      - `Recording.recorder`: each `RoutedModel` of `resumingProfile` holds the recorder strongly (`let recorder`). Removed.

    Item 3: every import is removed. The build and the full suite pass with no import put back.

    Not changed (as the task says): the MLX imports in `BootstrapTests.swift`, the 4 findings in `Tests/FoundationModelsRouterEvalSupport/CompactionEvalProgressLog.swift` (the `IntegrationTests` package uses them), and `Sources/`.

    No test was removed. No test was dead.
  timestamp: 2026-09-26T18:43:44.154445+00:00
- actor: claude-code
  id: 01m3fggqh0vztgbeft93w616a8
  text: |-
    ### implement — changed
    - evidence: 30 files in Tests/ (none in Sources/). Periphery total 1422 -> 1383, package files 54 -> 15, Tests/ 47 -> 10, no new finding (the 2 BackgroundTool.swift parameter findings in Sources/ also went away, because no conformance names the parameter now). swift test before 1458 + 17 + 19 = 1494, after 1458 + 17 + 19 = 1494, all pass. Clean build in a new scratch path: no warning in Sources/ or Tests/. swift build --package-path IntegrationTests --build-tests: Build complete.
    - next: /review
  timestamp: 2026-09-26T18:44:22.688324+00:00
position_column: doing
position_ordinal: '80'
title: Remove the dead code in the test targets that Periphery found
---
## Why

A full Periphery 3.8 scan (2026-09-26, all targets, `--retain-public`) found code in the test targets that nothing uses. This task removes only the items that are safe. The library items that only tests use (`RecordingLanguageModel`, `Tools.swift`, the guided `@Generable` path, and the small conveniences) are NOT in this task. They need a separate decision.

## What

Remove these items. Change no production file in `Sources/`.

1. Two unused test helpers:
   - `SessionEventLog.contains(_:)` in `Tests/FoundationModelsRouterTests/Helpers/SessionEventLog.swift:33`.
   - `makeAnswerEntryLists(_:toolOutputText:)` in `Tests/FoundationModelsRouterTests/Helpers/TranscriptTestHelpers.swift:91`.

2. Properties that the tests set but never read. Remove each property and each assignment to it:
   - `lastBackend` in `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:377` and in `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift:260`.
   - `callIndex` in `Tests/FoundationModelsRouterTests/Helpers/MeteredToolLoopLanguageModel.swift:49`.
   - `name` in `Tests/FoundationModelsRouterTests/Helpers/RecordingSummarizer.swift:68`.
   - `path`, `kind`, `changes` in `Tests/FoundationModelsRouterTests/MountedRunAttachmentCarrierTests.swift:24,27,31`.
   - `failure`, `tier` in `Tests/FoundationModelsRouterTests/OneCallCompactionTierTests.swift:22,25`.
   - `profile` in `Tests/FoundationModelsRouterTests/RepetitionStopRestoreTests.swift:100`.
   - `recordingProfile`, `recorder` in `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift:182,185`.
   - `text` in `Tests/FoundationModelsRouterPublicSurfaceTests/MessageQueuePublicSurfaceTests.swift:21`.
   
   CAUTION: if a property keeps an object alive for the full test (for example a profile that must stay resident, or a `Decodable` field that a comparison needs), do not remove it. Write the reason in a comment and keep it.

3. Unused `import` lines (the line numbers are from the scan):
   - `import FoundationModelsRouterTestSupport` in `Tests/FoundationModelsRouterTests/`: `AnswerCancellationEntryPointTests.swift:3`, `AnswerCancellationFixtures.swift:3`, `AnswerCancellationTests.swift:3`, `BackgroundToolRunnerTests.swift:3`, `CompactionSummaryRoleTests.swift:3`, `Helpers/CeilingStopCompactionModel.swift:3`, `Helpers/ToolResultCompactionModel.swift:3`, `SubmissionAnswerEventTests.swift:2`, `ToolFailureDeliveryTests.swift:3`, `ToolMountingTests.swift:3`.
   - `import FoundationModelsRouter` (or `@testable import`) in `Tests/FoundationModelsRouterTests/`: `AwaitedEventTests.swift:3`, `Helpers/AnswerDrivenRun.swift:4`, `Helpers/RejectingLanguageModel.swift:2`, `StubSessionBackendConcurrencyTests.swift:4`, `TranscriptEntryKindsTests.swift:6`. Also `Tests/FoundationModelsRouterTestSupport/ToolAnswerScenario.swift:2`.
   
   If the removal of an import stops the build, put the import back.

Do NOT change these items. They look unused, but they have a function:
- The MLX imports in `Tests/FoundationModelsRouterTests/BootstrapTests.swift`. The imports are the test.
- `modelLoadStepName`, `makeModelLoadStartedLine(ref:)`, `makeModelLoadReturnedLine(ref:seconds:)` and the `FoundationModelsRouter` import in `Tests/FoundationModelsRouterEvalSupport/CompactionEvalProgressLog.swift`. The `IntegrationTests` package uses them.
- The `// periphery:ignore` lines in `Sources/FoundationModelsRouter/Resolution/ModelPool.swift`.

Do not run `swift format`. It changes about 100 unrelated files.

## Result of each item (2026-09-26 run)

The rerun of Periphery found every item of items 1 to 3 still reported. ^qhf29tg and ^rbm6jtz removed none of them. The comment "Baseline (before the change)" has the full map.

- Removed: both helpers of item 1; `lastBackend` (2), `profile`, `recordingProfile`, `recorder`, `text` of item 2; all 16 imports of item 3.
- Kept, with a reason comment and `// periphery:ignore` (a read that Periphery cannot see): `name`, `failure`, `tier` (synthesized `Equatable`), `path`, `kind`, `changes` (`Decodable` plus synthesized `Equatable`), `callIndex` (the error description reads it by reflection).
- Also in the current output, not named above: the dead `import FoundationModelsRouterTestSupport` in `SummarizerPromptCacheTests.swift` (removed), and 4 unused parameters in `Helpers/ToolMountFixtures.swift` and `JointFitTests.swift` (internal names changed to `_`; the signatures stay).

## Subtasks

- [x] Remove the two unused helpers (item 1). <!-- proof: git diff of SessionEventLog.swift and TranscriptTestHelpers.swift; Periphery after reports neither -->
- [x] Remove the properties that are set but never read (item 2). <!-- proof: 6 removed, 7 kept with reason and marker; see "Result of each item" -->
- [x] Remove the unused imports (item 3). <!-- proof: 16 imports plus SummarizerPromptCacheTests removed; build passes with no import put back -->
- [x] Do a clean build and run the full test suite. <!-- proof: swift build --build-tests --scratch-path scratchpad/after1 = Build complete; swift test = 1458 + 17 + 19 pass -->

## Acceptance Criteria

- [x] `SessionEventLog.contains(_:)` and `makeAnswerEntryLists(_:toolOutputText:)` do not exist. <!-- proof: rg finds no declaration; Periphery after has no finding for them -->
- [x] Each property and import in items 2 and 3 is removed, or it has a comment that gives the reason to keep it. <!-- proof: 7 kept properties carry a reason comment line and `// periphery:ignore` -->
- [x] A clean build in a new scratch path (`swift build --build-tests --scratch-path <new dir>`) completes with zero new compiler warnings. <!-- proof: new scratch path after1; the only warnings are the SwiftPM "missing creator" line and 4 C++17 warnings in the mlx-swift checkout; no warning in Sources/ or Tests/ -->
- [x] `swift test` passes with the same count of tests as before the change, and with no new failures. <!-- proof: before 1458 + 17 + 19 = 1494; after 1458 + 17 + 19 = 1494; all pass -->
- [x] A new Periphery scan does not report the removed items. <!-- proof: Tests/ findings 47 -> 10; the 10 are the BootstrapTests MLX imports (6) and CompactionEvalProgressLog (4) that the task keeps; no new finding -->

## Tests

This task removes code and adds no behavior, so it adds no new test. The full existing suite is the regression guard.

- [x] Record the test count before the change: `swift test` (full suite, no `--filter`). A `--filter` that matches nothing exits 0, so it proves nothing. <!-- proof: 1458 + 17 + 19 = 1494, all pass -->
- [x] After the change: `swift build --build-tests --scratch-path <new dir>`. Expect zero new warnings. A build from the cache does not show warnings, so use a new scratch path. <!-- proof: scratchpad/after1, Build complete, no project warning -->
- [x] After the change: `swift test`. Expect the same count of tests, all green. <!-- proof: 1458 + 17 + 19 = 1494, all pass -->
- [x] `swift build --package-path IntegrationTests --build-tests`. Expect a successful build (the package uses `EvalSupport`). <!-- proof: Build complete; TestSupport compiled again after a touch -->
- [x] Periphery: `swift build --build-tests --scratch-path <dir>`, then `periphery scan --skip-build --index-store-path <dir>/out --retain-public --relative-results`. Expect no finding for the files in items 1 to 3. (The swift-build backend writes the index store to `<dir>/out`. It ignores `-Xswiftc -index-store-path`, and `.build/debug/index/store` does not exist.) <!-- proof: total 1422 -> 1383; package files 54 -> 15; Tests/ 47 -> 10; no finding for the files of items 1 to 3 -->

## Workflow

- Use `/tdd`. For a removal, the "failing test first" step is the baseline: record the green suite and its count before the first change. Then remove one group at a time, and build after each group. #dead-code