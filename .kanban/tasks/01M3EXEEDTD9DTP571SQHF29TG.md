---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fdbykvgq0zmmvfyd7f2rpt
  text: |-
    ### Research (implement)

    Baseline before any change: `swift test` (full suite, no filter) = 1487 + 17 + 19 = 1523 tests, all green (2 known issues, not failures).

    Baseline Periphery (`swift build --build-tests --scratch-path <scratch>/build-before`, then `periphery scan --skip-build --index-store-path <scratch>/build-before/out --retain-public --relative-results`): 7 findings in `Sources/` (AsyncSemaphore.swift:250 and :292, GenerationQueue.swift:95, BackgroundTool.swift:25 and :87, LiveModelLoader.swift:6 unused import MLXLLM, ModelPool.swift:25 superfluous ignore). Periphery 3.x is installed at /opt/homebrew/bin/periphery.

    Mapping of the moved line numbers to the current code:
    - `RoutedLLM.swift`: `makeRecordingLanguageModelHandle` is at line 321 (card: about 316), `makeLanguageModel()` at 357 (card: 352), `makeLanguageModel(resuming:)` at 381 (card: 376).
    - `ModelLoader.swift`: requirement `languageModel` at 120, trapping default at 132 (same as the card).
    - `LiveModelLoader.swift`: `package var languageModel` at 78 (same).
    - `LanguageModelProfile.swift`: `sessionSidecarWriter` at 78 (same).
    - `SessionTreeRestoration.swift`: the comment is at 547 (card: 543).
    - `CompactionSegmentTests.swift`: MARK at 510 (same). `TranscriptFidelityTests.swift`: the 4 tests call `makeLanguageModel()` at 808, 856, 892 and 944. `GenerationQueueTests.swift`: test at 191 (same).

    Other facts:
    - `recordingDirectory(forSessionId:recordingRoot:)` has one production caller, `makeSession`. `restoreSessionTree` does not call it (it uses `node.directory`); it calls `requireOwningProfile(apiName:)`. `SessionSidecarTests.swift:611` calls `recordingDirectory(forSessionId:)` with the default `recordingRoot`, so the default stays.
    - Tests to delete: RecordingLanguageModelTests 10, RecordingHandleResumeTests 5, NoteCompactionTests 7, CompactionSegmentTests 1, TranscriptFidelityTests 4, GenerationQueueTests 1 = 28. Expected after: 1487 - 28 = 1459 (+17 +19 = 1495).
    - `TranscriptDifferTests.swift:17` also names "the upcoming recording handle" in a doc comment. The card does not list it; I update it too.
    - `passQueue`: after this removal, the only production user (`MLXFoundationModelsContainer.languageModel`) is gone. Remaining users are tests only: `GenerationQueueWorkerTests.swift:501` (makes a wrapper with a pass queue) and `GenerationQueueTests.swift:188` (expects `passQueue == nil`). The card says: do NOT remove `passQueue` in this task; a follow-up task does it. No such follow-up task exists on the board (^n3rcz0x is the test-target dead-code task). Decision: keep `passQueue` here as the card orders, and add the follow-up task.
  timestamp: 2026-09-26T17:49:20.379283+00:00
- actor: claude-code
  id: 01m3fdyzmzb97y8f0n05s2khkv
  text: |-
    ### implement — changed
    - evidence: deleted 5 files (Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift, Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift, RecordingHandleResumeTests.swift, NoteCompactionTests.swift, IntegrationTests/.../RecordingHandleIntegrationTests.swift); renamed Helpers/UndrivenLanguageModel.swift to Helpers/UndrivenLanguageModelContainer.swift (git mv); edited RoutedLLM.swift, LanguageModelProfile.swift, ModelLoader.swift, LiveModelLoader.swift, ExecutorPassthrough.swift, SessionTreeRestoration.swift, SessionLanguageModel.swift, CompactionSegmentTests.swift, TranscriptFidelityTests.swift, GenerationQueueTests.swift, ScriptedToolCallingModel.swift, RoutedSessionCompactTests.swift, ProjectionExampleTests.swift, GuidedPublicSurfaceTests.swift, TranscriptDifferTests.swift, PropagationProbeIntegrationTests.swift, RealToolAnswerComparisonTests.swift, SessionTreeRestorationIntegrationTests.swift, generation-queue.md, compaction_plan.md.
    - tests: before 1487 + 17 + 19 = 1523; after 1459 + 17 + 19 = 1495, all green (2 known issues, as before). Drop 28 = the deleted tests: RecordingLanguageModelTests 10, RecordingHandleResumeTests 5, NoteCompactionTests 7, CompactionSegmentTests.makeLanguageModelResumingRestoresCompactionSegment 1, TranscriptFidelityTests handleInPlaceRewriteRecordsDivergenceMarkerAndRecovers + handleDivergedSyncRecordsItsNewEntriesThenTheMarker + handleShrinkRecordsUnseenEntriesThenTheMarker + unchangedToolSurfaceAcrossAnswersRecordsNoDivergence 4, GenerationQueueTests.liveContainerWrapsItsRawModelOnEachRead 1. Suites 174 to 171. Integration test RecordingHandleIntegrationTests (1 gated test) is also gone; the IntegrationTests package builds.
    - build: `swift build --build-tests --scratch-path <scratchpad>/build-after` complete, zero Swift compiler warnings.
    - periphery: Sources 7 findings before = 7 after (same declarations); test targets 47 = 47. No new finding; nothing left behind.
    - passQueue: after the removal only tests use it (GenerationQueueWorkerTests `thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput`, and one expectation in GenerationQueueTests). The card forbids its removal here, so it stays; the doc comments now say only a test makes such a wrapper. Follow-up task ^rbm6jtz removes it.
    - decision: the helper file was renamed to match its only type (UndrivenLanguageModelContainer). The design docs follow the "Superseded"/"Removed" marker style of generation-queue.md instead of a delete, so the history stays readable.
    - next: /review
  timestamp: 2026-09-26T17:59:44.031441+00:00
- actor: claude-code
  id: 01m3fekxkq8mwz1zfkcp77d246
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 7262313). 0 findings, 0 confirmed, 0 refuted. 14 validator passes ran, and 0 failed. The tools did not judge the 6 deleted files because those files do not exist. Deleted files are not new code. The review skipped the .kanban files (.reviewignore), compaction_plan.md and generation-queue.md (no validator matches them).
    - next: none. The task is in done.
  timestamp: 2026-09-26T18:11:10.071488+00:00
- actor: claude-code
  id: 01m3fennawbzqr1dmxpqmf8a57
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files deleted, 1 renamed, about 20 edited; follow-up ^rbm6jtz for passQueue
    - test: green — swift package clean then swift test, 1495 passed (1459+17+19), 0 failed, 0 skipped; drop of 28 equals the deleted tests; IntegrationTests build clean; Periphery shows no new finding
    - commit: 7262313
    - review: clean — 0 findings
  timestamp: 2026-09-26T18:12:07.132772+00:00
position_column: done
position_ordinal: ffffff9780
title: Remove RecordingLanguageModel, its RoutedModel factories, and its unit and integration tests
---
## Why

`RecordingLanguageModel` (added 2026-07-14, `76a31df`) is a recording `LanguageModel` handle for a consumer that drives its own `LanguageModelSession`. Production sessions do not use it: they record through `RoutedSessionActor`. The handle and its factories are `internal`, so no consumer package can call them. A search of FoundationModelsMultitool, FoundationModelsACPAgent, FoundationModelsAgents, FoundationModelsACPClient, CodeContextKit and AgentViewKit (2026-09-26) found no use. Only tests use it. User decision: remove it.

## What

### Production code (`Sources/FoundationModelsRouter/`)

- [x] Delete `Recording/RecordingLanguageModel.swift` (the full file: `RecordingLanguageModel`, `RecordingLanguageModelState`, `recordingLanguageModelLogger`). <!-- proof: git rm; `git status` shows D -->
- [x] `RoutedLLM.swift`: delete `makeRecordingLanguageModelHandle(...)` (about line 316), `makeLanguageModel()` (about line 352) and `makeLanguageModel(resuming:)` (about line 376). KEEP `requireOwningProfile(apiName:)` and `recordingDirectory(forSessionId:recordingRoot:)`: `makeSession` and `SessionTreeRestoration` use them. <!-- proof: the three were at 321, 357, 381; deleted. The doc of recordingDirectory now says "a fresh session" (not "session or handle"). -->
- [x] `LanguageModelProfile.swift:78`: delete `sessionSidecarWriter`. Only the handle reads it. <!-- proof: deleted; rg sessionSidecarWriter finds nothing -->
- [x] `Resolution/ModelLoader.swift`: delete the requirement `LoadedLLMContainer.languageModel` (about line 120) and its trapping `public` default (about line 132). This is a change to the public API. No consumer calls it. `ScriptedAgentContainer` in FoundationModelsAgents tests implements it, and that property then becomes an extra property that still compiles. <!-- proof: both deleted -->
- [x] `Resolution/LiveModelLoader.swift:78`: delete `package var languageModel`. <!-- proof: deleted, and the type doc no longer names it -->
- [x] Update the doc comments that name the handle: `Core/ExecutorPassthrough.swift:6-9`, `Recording/SessionTreeRestoration.swift:543`, and `Concurrency/SessionLanguageModel.swift` (the text about a wrapper "that the Router does not make" and the recording handle). Do NOT remove `passQueue` in this task. A follow-up task does that. <!-- proof: 3 files updated; SessionTreeRestoration comment was at 547; passQueue kept; follow-up task ^rbm6jtz created -->
- [x] After the removal, run Periphery (see Tests). If it reports a declaration that only the handle used (for example a `TranscriptDiffer` member), delete it too. Current check: each `TranscriptDiffer` member that the handle calls also has a caller in `RoutedSessionActor*`, so none is expected. <!-- proof: Sources findings identical before and after (7 = 7, same lines); nothing to delete -->

### Unit tests (`Tests/FoundationModelsRouterTests/`)

- [x] Delete these files: `RecordingLanguageModelTests.swift`, `RecordingHandleResumeTests.swift`, `NoteCompactionTests.swift`. <!-- proof: git rm; 10 + 5 + 7 = 22 tests -->
- [x] `CompactionSegmentTests.swift`: delete the test `makeLanguageModelResumingRestoresCompactionSegment` (the `// MARK: - makeLanguageModel(resuming:)` section, about line 510). Keep all other tests. <!-- proof: 1 test deleted -->
- [x] `TranscriptFidelityTests.swift`: delete the 4 tests that drive a bare handle with `makeLanguageModel()` and `sync` (about lines 794, 846, 882 and 928, the "bare handle ..." tests and `unchangedToolSurfaceAcrossAnswersRecordsNoDivergence`). Keep the tests that drive a `RoutedSession`. <!-- proof: 4 tests deleted with their MARK -->
- [x] `GenerationQueueTests.swift`: delete the test `liveContainerWrapsItsRawModelOnEachRead` (about line 191). <!-- proof: 1 test deleted -->
- [x] `Helpers/UndrivenLanguageModel.swift`: KEEP `UndrivenLanguageModelContainer` (about 9 suites use it), but delete its `languageModel` property and the `UndrivenLanguageModel` type, and update the doc comments. <!-- proof: done; file renamed with git mv to Helpers/UndrivenLanguageModelContainer.swift because the type UndrivenLanguageModel no longer exists -->
- [x] `Helpers/ScriptedToolCallingModel.swift:268`: delete the `languageModel` property if nothing reads it after the change. <!-- proof: rg finds no reader; deleted -->
- [x] `RoutedSessionCompactTests.swift:12`, `ProjectionExampleTests.swift:169`, `GuidedPublicSurfaceTests.swift:202`: update the doc comments that name the handle or `languageModel`. <!-- proof: 3 updated; also TranscriptDifferTests.swift:17 ("the upcoming recording handle") -->

### Integration tests (`IntegrationTests/`)

- [x] Delete `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift`. <!-- proof: git rm -->
- [x] Update the doc comments that refer to it: `PropagationProbeIntegrationTests.swift:144,178,247,268`, `RealToolAnswerComparisonTests.swift:110`, `SessionTreeRestorationIntegrationTests.swift:151,159`. Where a comment says "mirrors `RecordingHandleIntegrationTests/EchoTool`", describe the shape directly. <!-- proof: 7 comments updated; rg RecordingHandle finds nothing -->

### Design documents

- [x] `generation-queue.md:181`: remove the bullet "A recording handle (added by ^1psqdm9)", or mark it removed. <!-- proof: marked "Removed (^qhf29tg)"; the two section-2 lines that named RecordingLanguageModel are marked too -->
- [x] `compaction_plan.md:212`: update the reference to the recording handle. <!-- proof: "Removed (^qhf29tg)" note before the bare-session paragraph; also the intro, the section 1.5 bullet and the "One mechanism, two entry points" decision -->

Do not run `swift format`. It changes about 100 unrelated files.

## Acceptance Criteria

- [x] `rg 'RecordingLanguageModel|makeLanguageModel\(|noteCompaction\(' Sources Tests IntegrationTests Examples Tools` finds nothing. <!-- proof: empty output -->
- [x] `rg 'LoadedLLMContainer/languageModel|container\.languageModel' Sources Tests IntegrationTests` finds nothing. <!-- proof: empty output -->
- [x] `requireOwningProfile(apiName:)` and `recordingDirectory(forSessionId:recordingRoot:)` still exist, and `makeSession` and `restoreSessionTree` still use them. <!-- proof: both exist in RoutedLLM.swift; makeSession calls both; restoreSessionTree calls requireOwningProfile (it never called recordingDirectory; it uses node.directory) -->
- [x] A clean build in a new scratch path has zero new compiler warnings. <!-- proof: swift build --build-tests --scratch-path <scratchpad>/build-after: Build complete, zero Swift compiler warnings (only the SwiftPM cache note for swift-collections and the vendored mlx metal warnings) -->
- [x] `swift test` passes. The count of tests goes down by the count of the deleted tests only. There are no new failures. <!-- proof: 1459 + 17 + 19 = 1495, before 1523, drop 28 = the 28 deleted tests; 0 failures -->
- [x] The `IntegrationTests` package builds. <!-- proof: swift build --package-path IntegrationTests --build-tests: Build complete -->
- [x] A Periphery scan reports no new unused declaration that the removal left behind. <!-- proof: Sources 7 before = 7 after, same declarations; test targets 47 = 47, same declarations -->

## Tests

This task removes code. It adds no behavior, so it adds no new test. The remaining suite is the regression guard for the production recording path (`RoutedSessionActor`).

- [x] Before the change: run `swift test` (full suite, no `--filter`) and record the count of tests. A `--filter` that matches nothing exits 0, so it proves nothing. Count the tests that this task deletes. <!-- proof: 1487 + 17 + 19 = 1523; 28 to delete -->
- [x] After the change: `swift build --build-tests --scratch-path <new dir>`. Expect zero new warnings. A build from the cache does not show warnings. <!-- proof: new scratch path build-after, zero compiler warnings -->
- [x] After the change: `swift test`. Expect the count from before, less the deleted tests, all green. <!-- proof: 1495 = 1523 - 28, all green -->
- [x] `swift build --package-path IntegrationTests --build-tests`. Expect a successful build. <!-- proof: Build complete -->
- [x] Periphery: `swift build --build-tests --scratch-path <dir>`, then `periphery scan --skip-build --index-store-path <dir>/out --retain-public --relative-results`. Expect no new finding in `Sources/`, compared with the 2026-09-26 scan. <!-- proof: identical to the baseline scan of this session -->

## Workflow

- Use `/tdd`. For a removal, the "failing test first" step is the baseline: record the green suite and its count before the first change. Delete the tests first, then the production code, and build after each group.

## Follow-up (not in this task)

After this task, only a test creates a `SessionLanguageModel` with a `passQueue` (`GenerationQueueWorkerTests.swift:501`). The `passQueue` path in `Concurrency/SessionLanguageModel.swift` (`SessionLanguageModelState.passQueue`, the `passQueue.submit(pass)` branch of `Executor.respond`) is then dead. Remove it in a separate task: ^rbm6jtz. #dead-code