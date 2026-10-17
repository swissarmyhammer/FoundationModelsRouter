---
assignees:
- claude-code
depends_on:
- 01M546XB16JCG9XC4A1Z5Q57FB
position_column: todo
position_ordinal: '8780'
title: 'T1 follow-up b2: restoration suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the restoration suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork, restored session). With gates, use `SessionFixtureLifecycle.close(_:opening:)` (Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- When a helper makes the session and returns only events or text, close the session inside the helper, with a `defer` or `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path and a close on the success path.
- A restore test often closes the first session before it restores (to flush the journal). Keep that order; the `defer` then finds the close done. Close the restored session too.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [ ] PlanRestorationTests, PlanRestorationTests.swift: all 4 (local withRestoration / recordAndRestore).
- [ ] RestoreFidelityTests, RestoreFidelityTests.swift: all 3.
- [ ] RestoredRenderCounterTests, RestoredRenderCounterTests.swift: 2 of 7 (liveJournalRestoresTheLiveCounter, restoredRootAndForkReportTheLiveCounter).
- [ ] RepetitionStopRestoreTests, RepetitionStopRestoreTests.swift: 7 of 8 (all except cutRecordKeepsItsSchemaNameAndRoundTrips).
- [ ] SessionRestorationTests, SessionRestorationTests.swift: all 16 (local recordRoot / takeOneAnswerAfterRestoring / substituteInstructionsOnRestore).
- [ ] SessionTreeRestorationTests, SessionTreeRestorationTests.swift: 25 of 31 (all except the 5 restoredUsageState* value tests and recordedEmbeddingSlotThrowsSlotNotInProfile).
- [ ] SessionTreeRestorationLostRunTests, SessionTreeRestorationLostRunTests.swift: all 11.
- [ ] SessionTreeRestorationToolWiringTests, SessionTreeRestorationToolWiringTests.swift: all 11.
- [ ] StoredRecoveriesKeyTests, StoredRecoveriesKeyTests.swift: all 3 (local restoreFixture).
- [ ] SessionObserverSeedingTests, SessionObserverSeedingTests.swift: 1 of 11 (restoredToolAnswerSeedsRowsEqualToTheLiveProjection).
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup