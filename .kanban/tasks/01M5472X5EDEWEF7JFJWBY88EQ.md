---
assignees:
- claude-code
depends_on:
- 01M54727H1C10B483C56M1ZE24
position_column: todo
position_ordinal: '8e80'
title: 'T1 follow-up b9: elicitation, mail, public surface and example suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the elicitation, mail, run delivery, public surface, guided and example suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork, guided session). With gates, open the gates before the close (`SessionFixtureLifecycle.close(_:opening:)`, Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- Local `makeFixture` / `makeQueueFixture` / `runAnswer` helpers and `ScriptedSessionFixture` do not close. Close inside the helper or give the fixture an `end()`; use `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path.
- ExamplesTests and ProjectionExampleTests mirror code in Examples/. Close in the test, not in the example code, unless the example itself must show a close (then bring it to swissarmyhammer-96 first, because it is code that users read).
- A close ends open questions (elicitation ends) and journals them. Where a test counts elicitation ends or mail, check that the close does not change the count.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [ ] ElicitationRoutingTests, ElicitationRoutingTests.swift: 7 of 10 (formRoundTripThroughSessionRespond, declineResumesWithDeclineNotCancel, urlTwoStepThroughSessionSurface, doubleElicitResolvesIndependently, unknownAndMalformedIdsAreNoOps, idCaseDoesNotAffectRouting, respondNeverCrossesSessions).
- [ ] SessionMailQueueTests, SessionMailQueueTests.swift: 5 of 25 (respondAndSentMessageKeepTheirOrder, sentMessageComposesPendingEvents, settledRunWithNoMessageRunsADeliverySubmission, progressOnlyMailRunsNoSubmission, sentPromptFlattensEveryTextSegment).
- [ ] RunMessageDeliveryTests, RunMessageDeliveryTests.swift: all 6 (local makeFixture).
- [ ] RunProgressDeliveryTests, RunProgressDeliveryTests.swift: 5 of 7 (eachProgressEventArrivesLive, aPlanArrivesLiveWithItsPlan, theNextPromptHoldsNoPlan, aPlanEventIsWrittenAtOnce, consecutivePlanEventsAreEachWrittenAtOnce).
- [ ] ExamplesTests, ExamplesTests.swift: 7 of 12 (generateWithASession, streamAResponse, multiModelDirectGeneration, guidedRawConstrainedText, subagentFanOutByForking, proactiveCompactionBetweenAnswers, reactiveCompactionRecoversFromContextOverflow).
- [ ] ProjectionExampleTests, ProjectionExampleTests.swift: all 1 (ProjectionExampleHarness.makeSession).
- [ ] GuidedPublicSurfaceTests, GuidedPublicSurfaceTests.swift: 1 of 3 (minimalConformersDriveAnAnswer).
- [ ] RoutedSessionPublicSurfaceTests, RoutedSessionPublicSurfaceTests.swift: 3 of 4 (compactWithNoArgumentsMeasuresTheLiveTranscript, compactWithBudgetCompactsAgainstThatBudget, sendTextSendsThatTextAsOneMessage).
- [ ] GuidedGenerationTests, GuidedGenerationTests.swift: 6 of 16 (guidedSessionConstrainsAndRecords, ebnfGuidedSession, guidedSessionRejectsUnsupported, guidedSessionForwardsAutoCompactionBudget, guidedSessionAutoCompactsAtTrigger, grammarTravelsWithSession).
- [ ] DiscoveryPrimingTests, DiscoveryPrimingTests.swift: 13 of 15 (primingSeedsTheAnswerBeforeGeneration, primingOffLeavesConstructionUnchanged, seededEntriesRoundTripThroughRecording, failingDiscoveryGeneratesUnseededAndSurfacesTheFailure, unmountedToolSurfacesTheFailure, nonTextOutputSurfacesTheFailure, primingIsGenericOverTheArgumentProperty, mismatchedArgumentPropertySurfacesTheFailure, everyAnswerPrimesOnTopOfTheAccumulatedTranscript, primedAnswerAttachesPendingEventSegmentsToTheRealPrompt, forkInheritsPriming, primingSeedsAfterTheLeadingInstructionsEntry, guidedSessionPrimesDiscovery).
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup