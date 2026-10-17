---
assignees:
- claude-code
depends_on:
- 01M546XZ84YRXYSGWFCD2HAR85
position_column: todo
position_ordinal: '8880'
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
- [ ] SessionSidecarTests, SessionSidecarTests.swift: 14 of 27 (rootTwoForksAndGrandforkEachWriteOneSidecar, aRunWritesOnlySidecarsAndTranscripts, uninstructedForkAfterOneAnswerRecordsForkedAtEntryCountOfTwo, theSidecarExistsBeforeTheFirstTranscriptEvent, aDirectlyBuiltRootSessionActorWritesItsOwnSidecar, guidedSessionRecordsGrammarAndInstructionsAndForkInheritsThem, rootSidecarCarriesResolvedProfileFactsAndForkDoesNot, sidecarRecordsEachSessionsOwnWorkingDirectory, sessionVendedWithAgentSpawnRecordsItOnRootOnlyNotOnAFork, sessionVendedWithAgentSpawnStampsItOnTheSessionEventNotOnAFork, rootSessionWithoutAgentSpawnStampsNilOnTheSessionEvent, recordingLevelOffWritesNoSidecar, sessionWithUnwritableSidecarStillForksAndGenerates, concurrentForksEachWriteExactlyOneSidecar).
- [ ] PerSessionRecordingRootTests, PerSessionRecordingRootTests.swift: all 6.
- [ ] SettledTranscriptTests, SettledTranscriptTests.swift: 2 of 3 (aReadDuringASubmissionReturnsTheSettledEntriesAtOnce, aToolForksItsOwnSessionDuringTheSubmission).
- [ ] TranscriptFidelityTests, TranscriptFidelityTests.swift: all 13.
- [ ] TranscriptNestingTests, TranscriptNestingTests.swift: all 10.
- [ ] TranscriptReconstructionTests, TranscriptReconstructionTests.swift: 7 of 16 (reconstructsRootSessionEqualToBackendEntries, reconstructsWholeForkTreeMatchingEachNodesBackend, structuredSegmentRoundTrips, otherMapperErrorsAreWrappedWithSessionAndSeqContext, failedAnswerBodylessCloseIsSkippedWithoutError, firstAnswerTotalFailureWithNoBackendEntriesReconstructsEmpty, noCheckpointRestoresUnchanged).
- [ ] TranscriptTreeAccessTests, TranscriptTreeAccessTests.swift: 2 of 3 (returnsTheRouterLevelTree, explicitRecordingRootLoadsTheFlatLayout).
- [ ] TranscriptTreeTests, TranscriptTreeTests.swift: 11 of 15 (looksUpEverySessionByIdAlone, treeShapeMatchesIndex, eventsForSessionIsOwnDeltaOnly, effectiveEntryEventsCutsCorrectlyForGrandfork, effectiveEntryEventsForRootIsItsOwnEntries, forkWhoseRootNeverGeneratedStillReconstructs, deletingAParentSidecarThrowsNamingItsDirectory, deletingAChildDirectoryLoadsCleanWithoutIt, undecodableSidecarThrowsNamingItsDirectory, futureVersionSidecarFailsTheLoadWithTheTypedError, sessionAndEmbeddingEventsExcludedFromEffectiveEntries; local buildBranchingTree).
- [ ] BackgroundRunTranscriptTests, BackgroundRunTranscriptTests.swift: 7 of 10 (settledRunLandsAsCorrelatedToolOutputEntry, everyPostedEventIsJournaledInPostOrder, consecutiveProgressOfOneRunSharesOneRow, eventOfAnotherRunClosesTheOpenProgressRow, journaledCompletionStillReachesTheModel, publicReadFindsTheTerminalOnBothWritesOfIt, eventPostedBeforeTheFirstAnswerIsJournaledByTheAnswerItRides).
- [ ] MergedAndRedactionTests, MergedAndRedactionTests.swift: 2 of 15 (redactWiredThroughRouter, sinkFailureSwallowedUnderGating).
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup