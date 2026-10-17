---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54nk8ybhr5fcfpxstgjpctb
  text: |-
    Implementation notes (implement step):
    - New shared helper: protocol `SessionDirectoryFixture` in Helpers/SessionFixtureLifecycle.swift. It has `session` and `directory`. Its extension gives `end(opening:)` (open the gates, close the session with `SessionFixtureLifecycle.close(_:opening:)`, remove the directory) and `endingOnThrow(isolation:_:)` (runs a step through `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` with the session close as the cleanup). `SessionFixtureLifecycle.Started` conforms, and `SessionFixtureLifecycle.end(_:opening:)` now calls `started.end(opening:)`, so the close-then-remove step is in one place.
    - `CeilingProbeSessionFixture`, `RepeatingReasoningSessionFixture`, `StagedReasoningSessionFixture` and `AnswerLimitsSessionFixture` conform. All makes of these four fixtures are in the suites of this card, so each caller changed.
    - Each listed test: `defer { await fixture.end() }` right after it gets the fixture, in place of the old `defer` that only removed the directory. The close runs after all reads of the test, so no wait ends earlier.
    - Local helpers `runStagedAnswer`, `runProbeAnswer`, both `runAnswer` of ReasoningTokenLimitTests.swift, `runAnswer` of RepetitionStopTests and WatchStopUsageTests: the step after the make now uses `fixture.endingOnThrow`, so a throw closes the session and removes the directory.
    - TokenBudgetTests: the 4 listed tests had the same 6-line setup. One `@MainActor` helper `startSession()` now makes the directory, router, profile and session (directory removed when the resolve throws) and returns a `SessionFixtureLifecycle.Started` and the container. Each test ends it with `SessionFixtureLifecycle.end(started, opening: [])` in a `defer`, so the router stays alive to the end. The local `makeTempDir()` copy is gone; the helper uses `RouterTestFixtures.makeTempDir(prefix:)`.
    - No production code changed. IntegrationTests does not compile these files, so no IntegrationTests build.
    - Mistake to record: before the filtered run, one `pkill -x -f ... -P 1` call stopped all sourcekit-lsp processes, also those of other repos (FoundationModelsMultitool, ACPAgent, AgentViewKit, ACPClient, ACP, Extras, Agents). The rule says to stop only the sourcekit-lsp of this repo. The other editors must start their language server again.
  timestamp: 2026-10-17T10:12:53.835369+00:00
- actor: claude-code
  id: 01m54nkcgp5ew8x74qbxxf5v1r
  text: |-
    ### implement — changed
    - evidence: 14 files — Tests/FoundationModelsRouterTests/Helpers/SessionFixtureLifecycle.swift, Helpers/CeilingProbeLanguageModel.swift, Helpers/RepeatingReasoningModel.swift, Helpers/StagedReasoningModel.swift, Helpers/AnswerLimitsModel.swift, ReasoningStopRecoveryTests.swift, ReasoningTokenLimitTests.swift, RepetitionStopTests.swift, WatchStopUsageTests.swift, SubmissionFinishReasonTests.swift, PassTokenLimitTests.swift, AnswerTokenCeilingTests.swift, AnswerLimitsTests.swift, TokenBudgetTests.swift. `swift build --build-tests`: 0 errors, 0 compiler warnings. Filtered run `FoundationModelsRouterTests\.(10 listed suites)/`: 79 tests in 10 suites passed. Full `swift test` one time: 1827 tests in 224 suites passed with 6 known issues (the expected `withKnownIssue` wait tests); 26 tests in 14 suites passed; 19 tests in 3 suites passed.
    - next: review
  timestamp: 2026-10-17T10:12:57.494769+00:00
- actor: claude-code
  id: 01m54nx1r24ev44w9xpxtsths4
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 954964e9). Counts: findings 1, confirmed 1, refuted 1, attempted 14, failed 0. 6 `.kanban/` files are not reviewed (ignore rule).
    - dropped: 1 finding, by the written rule that drops findings that ask to refactor tests that already existed. Finding: `Tests/FoundationModelsRouterTests/ReasoningTokenLimitTests.swift:212` `duplication/duplication`. It asks to move the answer-and-end-on-throw step of `ReasoningTokenLimitTests.runAnswer` and `ReasoningEndRecoveryTests.runAnswer` into one shared fixture helper. Before this commit, the two helpers had the same wrapper-and-return shape (`RouterTestFixtures.removingDirectoryOnThrow`). The commit only changed the wrapper to `fixture.endingOnThrow` and changed the comment.
    - next: the task moves to done. No prior review findings are open.
  timestamp: 2026-10-17T10:18:14.146634+00:00
- actor: claude-code
  id: 01m54nxnn6w03v2nmxj0dd4nk8
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 14 test files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed
    - commit: 954964e9
    - review: clean — 1 engine finding dropped by the written rule (refactor of tests that existed before: ReasoningTokenLimitTests.swift:212)
  timestamp: 2026-10-17T10:18:34.534580+00:00
depends_on:
- 01M546ZF1JPP7J84196MQDTWTY
position_column: done
position_ordinal: ffffffff8680
title: 'T1 follow-up b5: reasoning, repetition and token limit suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the reasoning, repetition and token limit suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made. `close()` is idempotent.
- `CeilingProbeSessionFixture`, `RepeatingReasoningSessionFixture`, `AnswerLimitsSessionFixture` and the local `runAnswer` / `runProbeAnswer` / `runStagedAnswer` helpers do not close. Close inside the helper (a `defer` after the make), or give the fixture an `end()`. Use `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path. Card "T1 follow-up 6/6" changes the make of RepeatingReasoningSessionFixture; build on it.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [x] ReasoningStopRecoveryTests, ReasoningStopRecoveryTests.swift: all 8 (local runProbeAnswer / runStagedAnswer).
- [x] ReasoningTokenLimitTests, ReasoningTokenLimitTests.swift: all 5 (local runAnswer).
- [x] ReasoningEndRecoveryTests, ReasoningTokenLimitTests.swift: all 2 (local runAnswer; the other 3 suites in the file are value-only).
- [x] RepetitionStopTests, RepetitionStopTests.swift: all 5 (runAnswer over RepeatingReasoningSessionFixture.make; RepetitionDetectionDefaultTests is value-only).
- [x] WatchStopUsageTests, WatchStopUsageTests.swift: all 6 (runAnswer over RepeatingReasoningSessionFixture.make).
- [x] SubmissionFinishReasonTests, SubmissionFinishReasonTests.swift: 10 of 26 (answerEndedInsideReasoningReportsEndedInsideReasoning, reasoningTruncatedAtCeilingReportsMaxTokens, finishedAnswerReportsCompleted, finishReasonIsPerAnswer, answerTruncatedAtCeilingReportsMaxTokens, streamedAnswerTruncatedAtCeilingReportsMaxTokens, toolLoopAnswerTruncatedAtCeilingReportsMaxTokens, toolLoopFinishedAfterSpentToolCallReportsCompleted, streamedToolLoopAnswerTruncatedAtCeilingReportsMaxTokens, streamedToolLoopWithSilentLastCallReportsCompleted).
- [x] PassTokenLimitTests, PassTokenLimitTests.swift: 1 of 10 (sessionGivesTheBackendTheLimit).
- [x] AnswerTokenCeilingTests, AnswerTokenCeilingTests.swift: 2 of 5 (answerUsesResolvedContext, explicitCeilingIsKept).
- [x] AnswerLimitsTests, AnswerLimitsTests.swift: all 2 (AnswerLimitsSessionFixture.make).
- [x] TokenBudgetTests, TokenBudgetTests.swift: 4 of 10 (newSessionReportsZeroFill, singleAnswerFillIsDeltaOverContext, multiAnswerFillReflectsOnlyNewestDelta, failedAnswerLeavesFillUnchanged).
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup