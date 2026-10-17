---
assignees:
- claude-code
depends_on:
- 01M546EX6MD5G601R033YHSH6E
position_column: todo
position_ordinal: '8580'
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
- [ ] Wrap the resolve step of MeteredToolLoopSessionFixture.make in `RouterTestFixtures.removingDirectoryOnThrow(directory) { ... }`.
- [ ] Wrap the resolve step of RepeatingReasoningSessionFixture.make in the same helper.
- [ ] Check each caller in the list above: when the caller body throws after make, does the caller close the session and remove the directory (defer)? If a caller does not, add a `defer` that closes the session and removes the directory, or note it on the matching card of the "suites that never close a session" group.
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup