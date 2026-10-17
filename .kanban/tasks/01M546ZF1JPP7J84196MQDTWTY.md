---
assignees:
- claude-code
depends_on:
- 01M546YNM74MV9HRDSA7CNP2A0
position_column: todo
position_ordinal: '8980'
title: 'T1 follow-up b4: tool output, tool call and mount suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the tool output, tool call and mount suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork). With gates, use `SessionFixtureLifecycle.close(_:opening:)` (Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- `ScriptedSessionFixture`, `RejectingSessionFixture` and local `runAnswer` / `makeFixture` / `makeHarness` helpers do not close. Give the fixture an `end()` (close, then remove the directory), or close inside the helper; use `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path.
- A close sweeps open background runs and journals their terminals. In mount and outbox tests, check that the close does not add events that a later check counts.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [ ] IdenticalToolCallLimitTests, IdenticalToolCallLimitTests.swift: all 4 (local runAnswer; the 2 other suites in the file are value-only).
- [ ] ToolCallFailureAnswerTests, ToolCallFailureAnswerTests.swift: all 4 (ScriptedSessionFixture.make).
- [ ] ToolCallRepetitionStopTests, ToolCallRepetitionStopTests.swift: all 2 (local runAnswer).
- [ ] ToolCallRunJoinTests, ToolCallRunJoinTests.swift: 2 of 8 (invocationEventsCarryTheToolCallIdOfTheirRun, twoRunsOfOneToolJoinTheirOwnCalls).
- [ ] ToolContextMountSinkPublicSurfaceTests, ToolContextMountSinkPublicSurfaceTests.swift: all 4 (local driveAnswer).
- [ ] ToolInvocationLivenessTests, ToolInvocationLivenessTests.swift: 7 of 20 (liveInvocationEventArrivesWhileTheToolStillRuns, invocationRecordsAreDeliveryOnlyAndChangeNoRecording, reportPostedDuringTheSubmissionArrivesOnTheAnswerStreamAfterTheCloseRecord, runToCompletionCallReportsItsAttachmentsOnTheAnswerStream, contextBindingToolCallReportsItsAttachmentsOnTheAnswerStream, callWithNoAttachmentsProducesNoReport, reportIsNeverStagedOrRecorded).
- [ ] ToolOutputCappingTests, ToolOutputCappingTests.swift: 7 of 19 (makeSessionWithToolOutputLimitThreadsCappedTool, makeSessionWithNoToolOutputLimitLeavesToolUnwrapped, makeSessionWithNoBudgetLeavesToolUnwrapped, cappingComposesWithAmbientEventRoute, forkInheritsToolOutputLimitCapping, forkWithNoToolOutputLimitLeavesChildToolsUnwrapped, forkWithNoBudgetLeavesChildToolsUnwrapped).
- [ ] ToolOutputFeedbackTests, ToolOutputFeedbackTests.swift: all 2.
- [ ] ToolOutputProtectionSessionTests, ToolOutputProtectionSessionTests.swift: all 6.
- [ ] RejectedToolCallRetryTests, RejectedToolCallRetryTests.swift: all 2 (RejectingSessionFixture.make).
- [ ] ScriptedToolAnswerComparisonTests, ScriptedToolAnswerComparisonTests.swift: all 6 (local makeRespondRun / makeStreamRun).
- [ ] PerCallMountSessionTests, PerCallMountSessionTests.swift: all 4 (local makeHarness).
- [ ] MountedRunAttachmentCarrierTests, MountedRunAttachmentCarrierTests.swift: all 3 (local makeFixture / mountingAnswerEvents). Note: T1 listed "close on throw" for this file; the check found no close on the success path.
- [ ] RoutedSessionToolContextBindingTests, RoutedSessionToolContextBindingTests.swift: all 6 (local makeCancellationObservingSession).
- [ ] SessionOutboxToolWiringTests, SessionOutboxToolWiringTests.swift: all 29 (local makeBackgroundingSession / assert*ComposesBindOnly*).
- [ ] SubmissionBoundaryToolTests, SubmissionBoundaryToolTests.swift: all 5.
- [ ] SubmissionBoundaryToolPublicSurfaceTests, SubmissionBoundaryToolPublicSurfaceTests.swift: all 1 (ScriptedSessionFixture.make).
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup