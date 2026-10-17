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
- actor: claude-code
  id: 01m555yp72sm64b3gvpt2nb93k
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 1c32434e). Counts: findings 1, confirmed 1, refuted 0. 11 files reviewed, 4 `.kanban/` files not reviewed (ignore rule).
    - dropped: 1 finding, by the written rule of the `review` skill that drops findings that ask for a refactor of tests that already existed. The finding: `Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift:139` `duplication/duplication` — the catch block of startSummarizerBehindAFlashSubmission repeats the cleanup sequence of WaitingSummarizer.end(); extract one private static helper. Before this commit, the same two copies were in `end()` and in the catch block. The commit changed only the session close to `triggered.end()`.
    - next: none. The task is in done.
  timestamp: 2026-10-17T14:58:45.090106+00:00
- actor: claude-code
  id: 01m555zebfq77pqnykftd4qzt3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 11 test files
    - test: green — the one full swift test run of the implement step: 1835 tests in 226 suites + 26 + 19 passed
    - commit: 1c32434e
    - review: clean — 1 engine finding dropped by the written rule (SummarizerSubmissionTests.swift:139: the two cleanup copies were in the file before this commit; note: both copies come from earlier `t1-followup` commits ^z5q57fb and ^vkhrmcb, not from code before the T1 work)
  timestamp: 2026-10-17T14:59:09.807071+00:00
position_column: done
position_ordinal: ffffffff9180
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