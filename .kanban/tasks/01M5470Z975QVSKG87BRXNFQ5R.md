---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54pz2dds6g3pn02bqv5636c
  text: |-
    Implementation notes (for the next agent):
    - `ScriptedSessionFixture`, `MeteredToolLoopSessionFixture` and `RejectingSessionFixture` now conform to `SessionDirectoryFixture`, so a test ends each one with `defer { await fixture.end() }`. The local `AnswerFixture` of `SubmissionTracingTests` conforms too.
    - A close opens no span (only make, fork, submission, compact, embed, resolve and load open spans), so span reads are safe. A close can record cancelled mail and queue depth metrics, but each listed test reads its metrics before its `defer` runs, so no count changes.
    - New shared helpers, one for each file that had copies: `TelemetryContentSafetyTests.withFailingSpanSession(in:_:)`, `RouterMetricsTests.withHeldSessions(count:_:)` (opens the latch of the `PassObservingFixture` before each close), `RouterTelemetryLoggingTests.withSession(_:)`, `GenerationStallDiagnosticTests.close(_:openingHoldsOf:)` and `QueuedPassStallWatchTests.close(_:of:signalling:)`.
    - `AsyncSemaphore.wait()` does not end on a cancel. So each gate that a test holds (tool gate, step, `handshake.proceed`, `release`) gets permits in the `defer` before the close: one permit for each wait that can occur. A permit that no wait takes does nothing.
    - `HeldSessionBackend` ends its hold on a cancel, so the close of `hungSubmissionHasItsEnterRecord` needs no release.
    - `SessionLanguageModelPassWatchTests` makes an SDK `LanguageModelSession`. It has no end or cancel call (checked in the SDK swiftinterface), so it is out of scope (decision group 4(b)); a one-line comment is at the place.
    - Discovery for the later partial-close card: the other 7 tests of `GenerationStallDiagnosticTests` that use `makeStallingSession()` also never close their session (only the throw path of the helper closes). They are not on this card, so this card does not change them.
  timestamp: 2026-10-17T10:36:48.941033+00:00
- actor: claude-code
  id: 01m54q08h6dxc9xc1knjk8fr4z
  text: |-
    ### implement — changed
    - evidence: 18 test files changed (14 suites plus the fixtures `ScriptedSessionFixture`, `MeteredToolLoopSessionFixture`, `RejectingSessionFixture`). `swift build --build-tests`: no compiler warning (only the SwiftPM note "missing creator for mutated node" of the mlx bundle, which was there before). Filtered run of the 14 suites: 88 tests in 14 suites passed. Full `swift test` one time: 1827 tests in 224 suites passed with 6 known issues (the `withKnownIssue` wait tests that were there before), 26 tests in 14 suites passed, 19 tests in 3 suites passed; 0 failures. IntegrationTests not built: no file that it compiles changed.
    - next: review
  timestamp: 2026-10-17T10:37:27.974983+00:00
- actor: claude-code
  id: 01m54qdf8a7e0h6w0xtwe7eke6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 594f6afc). 18 files reviewed, 4 .kanban files not reviewed (ignore rule). Counts: findings 0, confirmed 0, refuted 3, attempted 21, failed 0, skipped 0. No earlier Review Findings section is on the task.
    - next: none. The task moved to done.
  timestamp: 2026-10-17T10:44:40.842601+00:00
- actor: claude-code
  id: 01m54qe5181z4da3bqqvgwpsff
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 18 test files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed, 0 failures
    - commit: 594f6afc
    - review: clean — 0 findings, 18 files reviewed
  timestamp: 2026-10-17T10:45:03.144103+00:00
depends_on:
- 01M54709HFVPM6E4HMV6ESTWCE
position_column: done
position_ordinal: ffffffff8780
title: 'T1 follow-up b6: telemetry, tracing and metering suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the telemetry, tracing, metering and stall suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork). With gates, use `SessionFixtureLifecycle.close(_:opening:)` (Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- `ScriptedSessionFixture`, `MeteredToolLoopSessionFixture` and local `makeFixture` / `driveScriptedSession` / `makeFailingSpanFixture` helpers do not close. Close inside the helper or give the fixture an `end()`; use `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path.
- A close can make spans, metrics or log records. When a test counts spans, metrics or records, check that the close does not change the count. If it does, read the count before the close and keep the `defer` for the throw path.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [x] ForkTracingTests, ForkTracingTests.swift: all 3.
- [x] SessionCreationTracingTests, SessionCreationTracingTests.swift: all 3.
- [x] SessionTracerWiringTests, SessionTracerWiringTests.swift: all 3.
- [x] SubmissionTracingTests, SubmissionTracingTests.swift: all 8 (local makeFixture).
- [x] ToolTracingTests, ToolTracingTests.swift: all 6 (ScriptedSessionFixture.make).
- [x] TelemetryContentSafetyTests, TelemetryContentSafetyTests.swift: all 1 (local driveScriptedSession).
- [x] TelemetryContentSafetyTests extension, TelemetryContentSafetyTests+FailedSpans.swift: 3 of 5 (failedCompactSpanRecordsOnlyTheErrorType, failedForkSpanRecordsOnlyTheErrorType, failedSubmissionSpanRecordsOnlyTheErrorType).
- [x] RouterMetricsTests, RouterMetricsTests.swift: 8 of 11 (generationCallsRecordTokensAndTimes, callerCompactionIsCounted, automaticCompactionIsCounted, waitingMessagesAreRecordedInTheSessionQueueDepth, cancelledMailIsCounted, compactionRecordsThePauseOfTheMailQueue, waitingSubmissionsAreRecordedInTheGenerationQueueGauge, forkKeepsTheExplicitMetricsFactory).
- [x] RouterTelemetryLoggingTests, RouterTelemetryLoggingTests.swift: 2 of 7 (pumpJobBindsTheExplicitLogger, forkKeepsTheExplicitLogger).
- [x] TokenUsageMeteringTests, TokenUsageMeteringTests.swift: all 6.
- [x] GenerationCallUsageTests, GenerationCallUsageTests.swift: 6 of 9 (threeCallsGiveThreeRecords, submissionStampStaysTheSum, recordsArriveLive, journalHoldsEachCall, lastCallFollowsItsResponseEntry, ceilingCallReportsMaxTokens).
- [x] EnterRecordTests, EnterRecordTests.swift: 2 of 5 (eachSubmissionWritesOneEnterRecord, hungSubmissionHasItsEnterRecord).
- [x] GenerationStallDiagnosticTests, GenerationStallDiagnosticTests.swift: 3 of 12 (aForkStartsWithTheIntervalOfItsParent, toolCallsWithNoTextReportNoStall, anAnswerThatStopsAfterAToolResultNamesIt).
- [x] QueuedPassStallWatchTests, QueuedPassStallWatchTests.swift: 4 of 7 (aWaitingSubmissionSendsItsQueuedIdBeforeItsStartAndNoStall, aToolBodyIsNotAStall, aHeldPassWithNoFragmentStillReportsAStall, aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass).
- [x] SessionLanguageModelPassWatchTests, SessionLanguageModelPassWatchTests.swift: all 2.
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup