---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m555n82raasc6kmpmcaqt3qj
  text: |-
    ### implement — changed
    - evidence: 11 test files under Tests/FoundationModelsRouterTests (Helpers/AutoCompactionFixtures.swift with the new shared fixture `CompactionSession`, AutoCompactionTests, CompactionTracingTests, OriginAndTerminalEventTests, RoutedSessionCompactTests, RouterMetricsTests, RoutedSessionPublicSurfaceTests, SummarizerSubmissionTests, ExamplesTests, ProjectionExampleTests, TranscriptReconstructionTests); filtered run 97 tests in 10 suites passed; full swift test 1835 tests in 226 suites passed (9 known issues), 26 in 14 and 19 in 3 passed. The board writes failed first with `No space left on device`; the orchestrator wrote this record after space was free.
    - next: commit, then review HEAD~1..HEAD.
  timestamp: 2026-10-17T14:53:35.704624+00:00
position_column: doing
position_ordinal: '80'
title: Test fixtures that never remove their temporary directory, also on success
---
Source: found during ^1b1zmq8.

These fixtures make a temporary directory, but they do not give it to the caller, and no step removes it when the test ends. Since ^1b1zmq8, each one removes the directory when its own steps throw. When the test body ends (with or without a throw), the directory stays.

- `AutoCompactionFixtures.makeTriggeredSession(budget:tools:tracer:samplingMode:flash:tempDirPrefix:)` (about 30 callers in AutoCompactionTests, CompactionTracingTests, OriginAndTerminalEventTests, RoutedSessionCompactTests).
- `AutoCompactionTests.makeOverflowSession(overflowsRemaining:overflowingCalls:recorder:)` and `AutoCompactionTests.makeRoomTestSession(target:overflowsRemaining:)`.
- `ExamplesTests.CompactionExampleHarness.makeSession(over:context:)`.
- `ProjectionExampleTests.ProjectionExampleHarness.makeSession()`.
- `TranscriptReconstructionTests.makeSingleCheckpointFixture()` and the tests `repeatedCompactionsOnlyNewestGovernsRestore` and `checkpointNamingMissingLiveWindowEntryThrows` (no Router; the test never removes the directory).

- [x] Give each fixture directory to its caller (or remove it in the fixture end step), and remove it in a `defer` at the call site, after the session close.
- [x] Use the shared `RouterTestFixtures.makeTempDir(prefix:)` and the existing `defer` pattern. Add no new local helper copy.
- [x] Run the full suite one time. #t1-followup