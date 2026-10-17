---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54j6mvpp00rb13a8zmvg7ms
  text: |-
    Discoveries:
    - In SessionSidecarTests `concurrentForksEachWriteExactlyOneSidecar`, a throwing task group can lose the forks that it made when one fork throws. Each task now gives a `Result` and does not throw. The test closes each fork that it made in a `defer`, and then gets the ids with `try`.
    - In that task group, `group.reduce(into:)` gave a region isolation error ("sending value of non-Sendable type risks causing data races"). A `for await` loop in the group body does not.
    - In TranscriptTreeTests, the helper `buildBranchingTree` now closes each session that it made when a step throws, and gives the four sessions to the caller. The new helper `close(_:)` closes them in the order grandfork, forkB, forkA, root. Each of the 7 callers closes the tree in a `defer`.
    - In SettledTranscriptTests `aReadDuringASubmissionReturnsTheSettledEntriesAtOnce`, the held call does not end on cancel. The `defer` uses `SessionFixtureLifecycle.close(_:opening:)` to open the release gate before the close.
    - In PerSessionRecordingRootTests, each restored tree root closes in a `defer` after the restore. The recorded root stays open until the test ends.
    - Each close `defer` comes after the directory remove `defer`, so the close runs first. Each close runs after the reads of the test, so the records that a close can write do not change what a test checks.
    - Some tests had `_ = root` or `_ = fork` lines to stop an unused-value warning. The `defer` now uses each value, so these lines are removed.
  timestamp: 2026-10-17T09:13:34.326502+00:00
- actor: claude-code
  id: 01m54j6qwe3x59ddg612qbbk7g
  text: |-
    ### implement — changed

    Evidence:
    - `swift build --build-tests`: Build complete, no source warnings.
    - `swift test --skip-build --filter 'FoundationModelsRouterTests\.(SessionSidecarTests|PerSessionRecordingRootTests|SettledTranscriptTests|TranscriptFidelityTests|TranscriptNestingTests|TranscriptReconstructionTests|TranscriptTreeAccessTests|TranscriptTreeTests|BackgroundRunTranscriptTests|MergedAndRedactionTests)/'`: 118 tests in 10 suites passed.
    - Full `swift test` (one run): 1827 tests in 224 suites passed with 6 known issues; 26 tests in 14 suites passed; 19 tests in 3 suites passed. XCTest: 0 tests.
    - Only files in Tests/FoundationModelsRouterTests changed. IntegrationTests does not compile them, so no IntegrationTests build.

    Next: /review.
  timestamp: 2026-10-17T09:13:37.422721+00:00
- actor: claude-code
  id: 01m54jtshm3t8f7qvyfy0zjf6y
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 8471adf3). 10 files reviewed. 0 findings, 0 confirmed, 0 refuted, 21 attempted, 0 failed, 0 skipped. 4 .kanban files are excluded by .reviewignore. The description has no prior review findings.
    - next: none. The task moved to done.
  timestamp: 2026-10-17T09:24:34.484810+00:00
- actor: claude-code
  id: 01m54jvgctj13jm8vxggx61mgx
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 test files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed
    - commit: 8471adf3
    - review: clean — 0 findings, 10 files reviewed
  timestamp: 2026-10-17T09:24:57.882061+00:00
depends_on:
- 01M546XZ84YRXYSGWFCD2HAR85
position_column: done
position_ordinal: ffffffff8480
title: 'T1 follow-up b3: transcript and recording suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the transcript and recording suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork, restored session, hand-built RoutedSessionActor). With gates, use `SessionFixtureLifecycle.close(_:opening:)` (Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- When a helper makes the session and returns only events or text, close the session inside the helper, with a `defer` or `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path and a close on the success path.
- A close can write journal or sidecar records. When a test reads the recording directory, check that the close before or after the read does not change what the test checks. If it does, close before the read and keep the `defer` for the throw path.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [x] SessionSidecarTests, SessionSidecarTests.swift: 14 of 27 (rootTwoForksAndGrandforkEachWriteOneSidecar, aRunWritesOnlySidecarsAndTranscripts, uninstructedForkAfterOneAnswerRecordsForkedAtEntryCountOfTwo, theSidecarExistsBeforeTheFirstTranscriptEvent, aDirectlyBuiltRootSessionActorWritesItsOwnSidecar, guidedSessionRecordsGrammarAndInstructionsAndForkInheritsThem, rootSidecarCarriesResolvedProfileFactsAndForkDoesNot, sidecarRecordsEachSessionsOwnWorkingDirectory, sessionVendedWithAgentSpawnRecordsItOnRootOnlyNotOnAFork, sessionVendedWithAgentSpawnStampsItOnTheSessionEventNotOnAFork, rootSessionWithoutAgentSpawnStampsNilOnTheSessionEvent, recordingLevelOffWritesNoSidecar, sessionWithUnwritableSidecarStillForksAndGenerates, concurrentForksEachWriteExactlyOneSidecar).
- [x] PerSessionRecordingRootTests, PerSessionRecordingRootTests.swift: all 6.
- [x] SettledTranscriptTests, SettledTranscriptTests.swift: 2 of 3 (aReadDuringASubmissionReturnsTheSettledEntriesAtOnce, aToolForksItsOwnSessionDuringTheSubmission).
- [x] TranscriptFidelityTests, TranscriptFidelityTests.swift: all 13.
- [x] TranscriptNestingTests, TranscriptNestingTests.swift: all 10.
- [x] TranscriptReconstructionTests, TranscriptReconstructionTests.swift: 7 of 16 (reconstructsRootSessionEqualToBackendEntries, reconstructsWholeForkTreeMatchingEachNodesBackend, structuredSegmentRoundTrips, otherMapperErrorsAreWrappedWithSessionAndSeqContext, failedAnswerBodylessCloseIsSkippedWithoutError, firstAnswerTotalFailureWithNoBackendEntriesReconstructsEmpty, noCheckpointRestoresUnchanged).
- [x] TranscriptTreeAccessTests, TranscriptTreeAccessTests.swift: 2 of 3 (returnsTheRouterLevelTree, explicitRecordingRootLoadsTheFlatLayout).
- [x] TranscriptTreeTests, TranscriptTreeTests.swift: 11 of 15 (looksUpEverySessionByIdAlone, treeShapeMatchesIndex, eventsForSessionIsOwnDeltaOnly, effectiveEntryEventsCutsCorrectlyForGrandfork, effectiveEntryEventsForRootIsItsOwnEntries, forkWhoseRootNeverGeneratedStillReconstructs, deletingAParentSidecarThrowsNamingItsDirectory, deletingAChildDirectoryLoadsCleanWithoutIt, undecodableSidecarThrowsNamingItsDirectory, futureVersionSidecarFailsTheLoadWithTheTypedError, sessionAndEmbeddingEventsExcludedFromEffectiveEntries; local buildBranchingTree).
- [x] BackgroundRunTranscriptTests, BackgroundRunTranscriptTests.swift: 7 of 10 (settledRunLandsAsCorrelatedToolOutputEntry, everyPostedEventIsJournaledInPostOrder, consecutiveProgressOfOneRunSharesOneRow, eventOfAnotherRunClosesTheOpenProgressRow, journaledCompletionStillReachesTheModel, publicReadFindsTheTerminalOnBothWritesOfIt, eventPostedBeforeTheFirstAnswerIsJournaledByTheAnswerItRides).
- [x] MergedAndRedactionTests, MergedAndRedactionTests.swift: 2 of 15 (redactWiredThroughRouter, sinkFailureSwallowedUnderGating).
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup