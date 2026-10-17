---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54wmgr92ypbhb8sje8deyah
  text: |-
    ### implement — changed

    All listed tests now close each session in a `defer` right after the session is made. The close runs after the test reads its values. A held gate or latch opens before the close.

    Changes, file by file (all under `Tests/FoundationModelsRouterTests/`):
    - `ElicitationRoutingTests`: `makeSession(pool:)` returns `SessionFixtureLifecycle.Started`. It removes the directory when the resolve throws. Each test uses `defer { await fixture.end() }`.
    - `SessionMailQueueTests`: `makeSession` returns `Started`, with the same throw path. All 12 callers use `fixture.end()`. The gated test uses `fixture.end(opening: [gate])`.
    - `RunMessageDeliveryTests` and `RunProgressDeliveryTests`: `Fixture` conforms to `SessionDirectoryFixture`. `tearDown` is `async` and calls `fixture.end()`. In `RunProgressDeliveryTests.makeFixture`, the throw path of the first respond also closes the session.
    - `ExamplesTests`, `ProjectionExampleTests`, `GuidedPublicSurfaceTests`, `GuidedGenerationTests`: a `defer { await session.close() }` in the test, not in the example code. The fan-out example closes each fork before the planner.
    - `RoutedSessionPublicSurfaceTests`: the 3 listed tests close in a `defer`.
    - `DiscoveryPrimingTests`: `Fixture` conforms to `SessionDirectoryFixture`. `makeFixture` removes the directory when the resolve throws. All 15 tests use `fixture.end()`. `forkInheritsPriming` closes the fork. The two feed tests keep their body close before they read the feed.

    Discoveries:
    - The temporary directories of the harness routers in `ExamplesTests` stay. They are router-only scope for the later card.
    - Other files still use the old `(session, dir)` pattern: `SubmissionBoundaryToolTests`, `SessionRunPlaneTests`, `PendingEventInjectionTests`, `BackgroundRunTranscriptTests`. They are not on this card.

    Evidence:
    - `swift build --build-tests`: no compiler warnings or errors.
    - `swift test --filter 'FoundationModelsRouterTests\.(ElicitationRoutingTests|SessionMailQueueTests|RunMessageDeliveryTests|RunProgressDeliveryTests|ExamplesTests|ProjectionExampleTests|GuidedPublicSurfaceTests|RoutedSessionPublicSurfaceTests|GuidedGenerationTests|DiscoveryPrimingTests)/'`: 99 tests in 10 suites passed.
    - Full `swift test`, one run: 1827 tests in 224 suites passed with 6 known issues (from `withKnownIssue` in files this card does not change). Also 26 tests in 14 suites passed, and 19 tests in 3 suites passed. XCTest: 0 tests.
    - IntegrationTests: not built, because no edited file is compiled by it.
  timestamp: 2026-10-17T12:15:54.633717+00:00
- actor: claude-code
  id: 01m54wy0z5j9ynf93hdjnpqype
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 053b33bc). 10 files reviewed. Counts: findings 0, confirmed 0, refuted 1, attempted 21, failed 0, skipped 0. The .reviewignore rule excluded 4 .kanban files.
    - next: none. The task is in done.
  timestamp: 2026-10-17T12:21:06.149832+00:00
- actor: claude-code
  id: 01m54x07we8p56f5j6vtcpzg0s
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 test files (the orchestrator checked the 11 subtask boxes after the review, because the work of each one is in commit 053b33bc)
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed
    - commit: 053b33bc
    - review: clean — 0 findings, 10 files reviewed
  timestamp: 2026-10-17T12:22:18.766869+00:00
depends_on:
- 01M54727H1C10B483C56M1ZE24
position_column: done
position_ordinal: ffffffff8b80
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
- [x] ElicitationRoutingTests, ElicitationRoutingTests.swift: 7 of 10 (formRoundTripThroughSessionRespond, declineResumesWithDeclineNotCancel, urlTwoStepThroughSessionSurface, doubleElicitResolvesIndependently, unknownAndMalformedIdsAreNoOps, idCaseDoesNotAffectRouting, respondNeverCrossesSessions).
- [x] SessionMailQueueTests, SessionMailQueueTests.swift: 5 of 25 (respondAndSentMessageKeepTheirOrder, sentMessageComposesPendingEvents, settledRunWithNoMessageRunsADeliverySubmission, progressOnlyMailRunsNoSubmission, sentPromptFlattensEveryTextSegment).
- [x] RunMessageDeliveryTests, RunMessageDeliveryTests.swift: all 6 (local makeFixture).
- [x] RunProgressDeliveryTests, RunProgressDeliveryTests.swift: 5 of 7 (eachProgressEventArrivesLive, aPlanArrivesLiveWithItsPlan, theNextPromptHoldsNoPlan, aPlanEventIsWrittenAtOnce, consecutivePlanEventsAreEachWrittenAtOnce).
- [x] ExamplesTests, ExamplesTests.swift: 7 of 12 (generateWithASession, streamAResponse, multiModelDirectGeneration, guidedRawConstrainedText, subagentFanOutByForking, proactiveCompactionBetweenAnswers, reactiveCompactionRecoversFromContextOverflow).
- [x] ProjectionExampleTests, ProjectionExampleTests.swift: all 1 (ProjectionExampleHarness.makeSession).
- [x] GuidedPublicSurfaceTests, GuidedPublicSurfaceTests.swift: 1 of 3 (minimalConformersDriveAnAnswer).
- [x] RoutedSessionPublicSurfaceTests, RoutedSessionPublicSurfaceTests.swift: 3 of 4 (compactWithNoArgumentsMeasuresTheLiveTranscript, compactWithBudgetCompactsAgainstThatBudget, sendTextSendsThatTextAsOneMessage).
- [x] GuidedGenerationTests, GuidedGenerationTests.swift: 6 of 16 (guidedSessionConstrainsAndRecords, ebnfGuidedSession, guidedSessionRejectsUnsupported, guidedSessionForwardsAutoCompactionBudget, guidedSessionAutoCompactsAtTrigger, grammarTravelsWithSession).
- [x] DiscoveryPrimingTests, DiscoveryPrimingTests.swift: 13 of 15 (primingSeedsTheAnswerBeforeGeneration, primingOffLeavesConstructionUnchanged, seededEntriesRoundTripThroughRecording, failingDiscoveryGeneratesUnseededAndSurfacesTheFailure, unmountedToolSurfacesTheFailure, nonTextOutputSurfacesTheFailure, primingIsGenericOverTheArgumentProperty, mismatchedArgumentPropertySurfacesTheFailure, everyAnswerPrimesOnTopOfTheAccumulatedTranscript, primedAnswerAttachesPendingEventSegmentsToTheRealPrompt, forkInheritsPriming, primingSeedsAfterTheLeadingInstructionsEntry, guidedSessionPrimesDiscovery).
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup