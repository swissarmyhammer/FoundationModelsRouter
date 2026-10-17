---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54dzymb3bdfn512khv799ah
  text: |-
    Implementation done.
    - MeteredToolLoopSessionFixture.make (Tests/FoundationModelsRouterTests/Helpers/MeteredToolLoopLanguageModel.swift) and RepeatingReasoningSessionFixture.make (Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift) now put `router.resolve` in `RouterTestFixtures.removingDirectoryOnThrow(directory) { ... }`. The `- Throws:` doc of each make now says that it removes the temp directory before it throws. This is the same form as StagedReasoningSessionFixture.make.
    - No unit test was added for the throw path: each make sets its own StubModelLoader, so a test cannot make `resolve` throw without a new parameter only for that test. The sibling fixtures that got the same change also have no such test.
    - Caller check (directory): all 7 callers remove the directory on success. GenerationCallUsageTests, CompactionRenderCounterTests, RestoredRenderCounterTests and RouterMetricsTests use `defer { try? FileManager.default.removeItem(at: fixture.directory) }` after make. RepetitionStopTests, ReasoningTokenLimitTests and WatchStopUsageTests put the answer in `removingDirectoryOnThrow(fixture.directory)`, and the test removes the directory after the return. Now a throw in make also removes the directory.
    - Caller check (session close): no caller closes the session. The group cards already list each caller, so no new note was necessary: b1 `^z5q57fb` (CompactionRenderCounterTests), b2 `^d2har85` (RestoredRenderCounterTests liveJournalRestoresTheLiveCounter), b5 `^6estwce` (ReasoningTokenLimitTests, RepetitionStopTests, WatchStopUsageTests), b6 `^rxnfq5r` (RouterMetricsTests generationCallsRecordTokensAndTimes, GenerationCallUsageTests 6 of 9).
    - Note: the move to `doing` gives a 166k character result; the move was done.
  timestamp: 2026-10-17T08:00:00.651908+00:00
- actor: claude-code
  id: 01m54e0ehjsr3gakcr6qmn6zs9
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/Helpers/MeteredToolLoopLanguageModel.swift, Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift. Filter run `swift test --filter 'FoundationModelsRouterTests\.(GenerationCallUsageTests|RepetitionStopTests)/'`: 14 tests in 2 suites passed. Full `swift test` one time, exit 0: swift-testing 1827 tests in 224 suites passed with 6 known issues; 26 tests in 14 suites passed; 19 tests in 3 suites passed; XCTest 0 tests 3 times, 0 failures. One build warning only, from the build system: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle, not from the changed files. IntegrationTests does not compile these files, so it was not built.
    - next: `/review`.
  timestamp: 2026-10-17T08:00:16.946348+00:00
- actor: claude-code
  id: 01m54e4f5t25fgpnnkb3tt9q3y
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit bb554738). Counts: findings 0, confirmed 0, refuted 2, attempted 7, failed 0. Two Swift files were reviewed. Four .kanban files were not reviewed (.reviewignore).
    - next: The task is in done. No work stays open.
  timestamp: 2026-10-17T08:02:28.666134+00:00
- actor: claude-code
  id: 01m54e5c4w71f1x6bzz02pf3ze
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 test helper files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed, exit 0
    - commit: bb554738
    - review: clean — 0 findings, 2 files reviewed
  timestamp: 2026-10-17T08:02:58.332862+00:00
depends_on:
- 01M546EX6MD5G601R033YHSH6E
position_column: done
position_ordinal: ffffffff8180
title: 'T1 follow-up 6/6: MeteredToolLoopSessionFixture.make and RepeatingReasoningSessionFixture.make remove the temp directory on a throw'
---
Source: task ^dbr1dqy (T1 audit, done). The audit comment "kinds of waits checked and left" names this helper change as not made: temp-directory cleanup on throw in MeteredToolLoopSessionFixture.make and RepeatingReasoningSessionFixture.make. The later shared helper `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:156) now makes this a small change.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

Helpers (checked against the code on 2026-10-17):
- `MeteredToolLoopSessionFixture.make(calls:context:budget:tempDirPrefix:)` in Tests/FoundationModelsRouterTests/Helpers/MeteredToolLoopLanguageModel.swift:176. The `router.resolve` at line 190 can throw after `makeTempDir` made the directory. The directory then stays.
- `RepeatingReasoningSessionFixture.make(script:repeatsAfterStop:detection:tools:tempDirPrefix:)` in Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift:459. The `router.resolve` at line 475 can throw in the same way.

Failure event: not a wait. The rule part is "a fixture closes also when the body throws". No session exists yet at the throw, so only the directory needs removal.

Callers (no change needed at the callers; check that each caller still removes the directory on its own success path and also when its body throws):
- MeteredToolLoopSessionFixture.make: GenerationCallUsageTests.swift:54, CompactionRenderCounterTests.swift:302, RestoredRenderCounterTests.swift:251, RouterMetricsTests.swift:120.
- RepeatingReasoningSessionFixture.make: RepetitionStopTests.swift:78, WatchStopUsageTests.swift:86, ReasoningTokenLimitTests.swift:62.

Plan:
- [x] Wrap the resolve step of MeteredToolLoopSessionFixture.make in `RouterTestFixtures.removingDirectoryOnThrow(directory) { ... }`.
- [x] Wrap the resolve step of RepeatingReasoningSessionFixture.make in the same helper.
- [x] Check each caller in the list above: when the caller body throws after make, does the caller close the session and remove the directory (defer)? If a caller does not, add a `defer` that closes the session and removes the directory, or note it on the matching card of the "suites that never close a session" group.
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup