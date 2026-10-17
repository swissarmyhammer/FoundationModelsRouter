---
assignees:
- claude-code
depends_on:
- 01M54709HFVPM6E4HMV6ESTWCE
position_column: todo
position_ordinal: 8b80
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
- [ ] ForkTracingTests, ForkTracingTests.swift: all 3.
- [ ] SessionCreationTracingTests, SessionCreationTracingTests.swift: all 3.
- [ ] SessionTracerWiringTests, SessionTracerWiringTests.swift: all 3.
- [ ] SubmissionTracingTests, SubmissionTracingTests.swift: all 8 (local makeFixture).
- [ ] ToolTracingTests, ToolTracingTests.swift: all 6 (ScriptedSessionFixture.make).
- [ ] TelemetryContentSafetyTests, TelemetryContentSafetyTests.swift: all 1 (local driveScriptedSession).
- [ ] TelemetryContentSafetyTests extension, TelemetryContentSafetyTests+FailedSpans.swift: 3 of 5 (failedCompactSpanRecordsOnlyTheErrorType, failedForkSpanRecordsOnlyTheErrorType, failedSubmissionSpanRecordsOnlyTheErrorType).
- [ ] RouterMetricsTests, RouterMetricsTests.swift: 8 of 11 (generationCallsRecordTokensAndTimes, callerCompactionIsCounted, automaticCompactionIsCounted, waitingMessagesAreRecordedInTheSessionQueueDepth, cancelledMailIsCounted, compactionRecordsThePauseOfTheMailQueue, waitingSubmissionsAreRecordedInTheGenerationQueueGauge, forkKeepsTheExplicitMetricsFactory).
- [ ] RouterTelemetryLoggingTests, RouterTelemetryLoggingTests.swift: 2 of 7 (pumpJobBindsTheExplicitLogger, forkKeepsTheExplicitLogger).
- [ ] TokenUsageMeteringTests, TokenUsageMeteringTests.swift: all 6.
- [ ] GenerationCallUsageTests, GenerationCallUsageTests.swift: 6 of 9 (threeCallsGiveThreeRecords, submissionStampStaysTheSum, recordsArriveLive, journalHoldsEachCall, lastCallFollowsItsResponseEntry, ceilingCallReportsMaxTokens).
- [ ] EnterRecordTests, EnterRecordTests.swift: 2 of 5 (eachSubmissionWritesOneEnterRecord, hungSubmissionHasItsEnterRecord).
- [ ] GenerationStallDiagnosticTests, GenerationStallDiagnosticTests.swift: 3 of 12 (aForkStartsWithTheIntervalOfItsParent, toolCallsWithNoTextReportNoStall, anAnswerThatStopsAfterAToolResultNamesIt).
- [ ] QueuedPassStallWatchTests, QueuedPassStallWatchTests.swift: 4 of 7 (aWaitingSubmissionSendsItsQueuedIdBeforeItsStartAndNoStall, aToolBodyIsNotAStall, aHeldPassWithNoFragmentStillReportsAStall, aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass).
- [ ] SessionLanguageModelPassWatchTests, SessionLanguageModelPassWatchTests.swift: all 2.
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup