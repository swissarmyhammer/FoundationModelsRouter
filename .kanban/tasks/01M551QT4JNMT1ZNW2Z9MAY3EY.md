---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: Test fixtures that never remove their temporary directory, also on success
---
Source: found during ^1b1zmq8.

These fixtures make a temporary directory, but they do not give it to the caller, and no step removes it when the test ends. Since ^1b1zmq8, each one removes the directory when its own steps throw. When the test body ends (with or without a throw), the directory stays.

- `AutoCompactionFixtures.makeTriggeredSession(budget:tools:tracer:samplingMode:flash:tempDirPrefix:)` (about 30 callers in AutoCompactionTests, CompactionTracingTests, OriginAndTerminalEventTests, RoutedSessionCompactTests).
- `AutoCompactionTests.makeOverflowSession(overflowsRemaining:overflowingCalls:recorder:)` and `AutoCompactionTests.makeRoomTestSession(target:overflowsRemaining:)`.
- `ExamplesTests.CompactionExampleHarness.makeSession(over:context:)`.
- `ProjectionExampleTests.ProjectionExampleHarness.makeSession()`.
- `TranscriptReconstructionTests.makeSingleCheckpointFixture()` and the tests `repeatedCompactionsOnlyNewestGovernsRestore` and `checkpointNamingMissingLiveWindowEntryThrows` (no Router; the test never removes the directory).

- [ ] Give each fixture directory to its caller (or remove it in the fixture end step), and remove it in a `defer` at the call site, after the session close.
- [ ] Use the shared `RouterTestFixtures.makeTempDir(prefix:)` and the existing `defer` pattern. Add no new local helper copy.
- [ ] Run the full suite one time. #t1-followup