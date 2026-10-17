---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54gk20w3rmf3970dgvqhzbv
  text: |-
    Implementation notes (implement step):
    - Each listed test now closes each session that it makes in a `defer`, right after the session is made: the root, each fork, and each session of a restored tree (`restored.root` and `restored.session(<fork id>)`). Each close runs after the reads of the test, so no wait ends earlier than before.
    - Recorded sessions stay open until the restore and the checks end, as before. This is load-bearing in the lost-run suite: a close before the restore sweeps the runs and journals terminals, and then no orphan stays. The closes are only at the end of the test.
    - Helpers that make a session now close it on a throw with `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)`, and give the session to the caller on success: `PlanRestorationTests.recordAndRestore` (the `Restoration` struct now holds `recorded`), `RepetitionStopRestoreTests.runStoppedAnswer`, `SessionRestorationTests.recordRoot` (`Recording.root`) and `takeOneAnswerAfterRestoring` (now returns `AnsweredRestore` with the restored session), `SessionTreeRestorationLostRunTests.recordAndRestore` (the tuple now holds `recorded`), `StoredRecoveriesKeyTests.restoreFixture` (closes the root when the cast fails).
    - Helpers that return only values close their sessions inside in a `defer`, after their reads: `SessionRestorationTests.substituteInstructionsOnRestore`, `SessionTreeRestorationTests.expectForkAndRestoreKeep` and `restoredUserPresences`.
    - A `try #require(x as? RoutedSessionActor)` on a new fork now comes after the `defer` of the fork, so a failed cast does not leave the fork open (`expectForkAndRestoreKeep`, `restoredForkRenderEqualsTheLiveForkRender`).
    - Tests where the restore must throw: the closure now closes the root of a tree that a wrong restore returns (`try await ...restoreSessionTree(...).root.close()`), so a failing test leaves no session. `recordedEmbeddingSlotThrowsSlotNotInProfile` is not on the card and did not change.
    - No held call or gate without a cancel is in these tests. The gate of `settledRunReportIsCarriedWhole` opens before the run, and its harness is a run plane only (no session).
    - Tool note: the files tool echoes the whole file after each edit. For the four large files, one full write of each file costs less context than many edits; the diff was checked line by line after each write.
    - No production code changed. No IntegrationTests file changed, so no IntegrationTests build.
  timestamp: 2026-10-17T08:45:23.868864+00:00
- actor: claude-code
  id: 01m54gk9e23gwrv8s7vgahfd9v
  text: |-
    ### implement — changed
    - evidence: 10 files under Tests/FoundationModelsRouterTests/ (PlanRestorationTests, RestoreFidelityTests, RestoredRenderCounterTests, RepetitionStopRestoreTests, SessionRestorationTests, SessionTreeRestorationTests, SessionTreeRestorationLostRunTests, SessionTreeRestorationToolWiringTests, StoredRecoveriesKeyTests, SessionObserverSeedingTests). `swift build --build-tests` after a touch of the 10 files: 0 errors, 0 compiler warnings. Filtered `swift test --filter 'FoundationModelsRouterTests\.(<10 suites>)/'`: 105 tests in 10 suites passed. Full `swift test` one time: 1827 tests in 224 suites passed with 6 known issues (the 6 existing `withKnownIssue` sites); 26 tests in 14 suites passed; 19 tests in 3 suites passed.
    - next: review
  timestamp: 2026-10-17T08:45:31.458428+00:00
- actor: claude-code
  id: 01m54gxb4e266e50kh28h3bvb6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 51e8acec). 10 files reviewed, 4 .kanban files not reviewed (ignore rule). counts: findings 0, confirmed 0, refuted 0, attempted 21, failed 0, skipped 0.
    - next: none. The task moved to done.
  timestamp: 2026-10-17T08:51:00.878134+00:00
- actor: claude-code
  id: 01m54gy763hqdnmgnatabx46v1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 test files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed
    - commit: 51e8acec
    - review: clean — 0 findings, 10 files reviewed
  timestamp: 2026-10-17T08:51:29.603450+00:00
depends_on:
- 01M546XB16JCG9XC4A1Z5Q57FB
position_column: done
position_ordinal: ffffffff8380
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
- [x] PlanRestorationTests, PlanRestorationTests.swift: all 4 (local withRestoration / recordAndRestore).
- [x] RestoreFidelityTests, RestoreFidelityTests.swift: all 3.
- [x] RestoredRenderCounterTests, RestoredRenderCounterTests.swift: 2 of 7 (liveJournalRestoresTheLiveCounter, restoredRootAndForkReportTheLiveCounter).
- [x] RepetitionStopRestoreTests, RepetitionStopRestoreTests.swift: 7 of 8 (all except cutRecordKeepsItsSchemaNameAndRoundTrips).
- [x] SessionRestorationTests, SessionRestorationTests.swift: all 16 (local recordRoot / takeOneAnswerAfterRestoring / substituteInstructionsOnRestore).
- [x] SessionTreeRestorationTests, SessionTreeRestorationTests.swift: 25 of 31 (all except the 5 restoredUsageState* value tests and recordedEmbeddingSlotThrowsSlotNotInProfile).
- [x] SessionTreeRestorationLostRunTests, SessionTreeRestorationLostRunTests.swift: all 11.
- [x] SessionTreeRestorationToolWiringTests, SessionTreeRestorationToolWiringTests.swift: all 11.
- [x] StoredRecoveriesKeyTests, StoredRecoveriesKeyTests.swift: all 3 (local restoreFixture).
- [x] SessionObserverSeedingTests, SessionObserverSeedingTests.swift: 1 of 11 (restoredToolAnswerSeedsRowsEqualToTheLiveProjection).
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup