---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3e6r51k5mn1vb2bcav6j47c
  text: |-
    Research (implement, picked up):
    - The resets are already for each answer since ^3qx0mpt. `runAnswer(of:settledRunTokens:)` in `RoutedSessionActorPump.swift` sets `compactionYieldsStopped = false` and `repetitionWatch.recoveriesThisTurn = 0` before the first submission of each answer. A continuation (`runTurnAttempt(isContinuation: true)`, `runContinuation`, `recoverFailedAttempt`) does not reset them.
    - The overflow retry is not stored state. `runTurnWork` gives `allowOverflowRetry: autoCompactionBudget != nil` to the first submission of each answer. Each continuation carries the value of its attempt (`StoppedAttempt.allowOverflowRetry`), and the retry gives `false`. Thus it is one retry for each answer by construction.
    - No test proves the reset for each answer. `RepetitionStopTests.recoveriesStopAtTheConfiguredCount` proves the count inside one answer only.
    - `Package.swift` already excludes `Fixtures` from the test target (commit f87c7e8), and the fixture is tracked. The orchestrator says: a test reads it from disk at a path relative to its source file. So the fixture stays excluded, not a resource. The "unhandled file" warning is gone with the exclude.
    - `recoveriesPerTurn`, `defaultRecoveriesPerTurn`, `isFailedTurnClose`: public; used in Sources (RepetitionDetection, RepetitionWatch, TokenBudget, TurnExecution docs) and in tests. `RepetitionDetection` has a synthesized `Codable`.
    - A compaction that applies no summary: an over-trigger ceiling stop whose counted transcript is under the target ("nothing to compact"). This sets `compactionYieldsStopped`.
  timestamp: 2026-09-26T06:34:25.715740+00:00
- actor: claude-code
  id: 01m3e787g8d6vy4phpa8f7evz5
  text: |-
    Decisions (implement):
    1. Names. `RepetitionDetection.recoveriesPerTurn` -> `recoveriesPerAnswer`, `defaultRecoveriesPerTurn` -> `defaultRecoveriesPerAnswer`, init label `recoveriesPerAnswer:`. A private `CodingKeys` keeps the stored key: `case recoveriesPerAnswer = "recoveriesPerTurn"`. No `schemaVersion` change. The internal counter `RepetitionWatchState.recoveriesThisTurn` -> `recoveriesThisAnswer`. `TranscriptEvent.isFailedTurnClose` -> `isFailedAnswerClose` (a computed value from the event shape, so no byte on disk changes). Reason: the user wants the "turn" concept gone; the design (5.6) keeps only the stored key.
    2. No deprecated alias for the old public names. Reason: the earlier renames of this design (TurnOutcome -> SessionAnswer, TurnID -> SubmissionID) kept no alias, and ^d7d777f owns the consumer updates. A rg over IntegrationTests, Examples and the docc shows no use of the old names.
    3. The log line and `RepetitionStop.description` now name `recoveriesPerAnswer = N` and say "so the answer ends". Reason: the log line names each value by its property name (task ^1hcwaqy); the test `repeatingCallStopsWithLogAndEvent` is restated to the new name.
    4. The resets for each answer move into one named method, `startAnswerLimits()` in `RoutedSessionActorPump.swift`, which the pump calls one time before the first submission of an answer. The overflow retry stays a parameter, not stored state: `runTurnWork` gives the permission to the first submission of each answer, and each continuation carries it in `StoppedAttempt`. The doc of `startAnswerLimits()` says so.
    5. Fixture. It is tracked (f87c7e8) and the test target excludes `Fixtures` (Package.swift). I keep the exclude and do not declare a resource: the orchestrator said the test reads it from disk at a path relative to its source file. The exclude already removes the "unhandled file" warning.
    6. The fixture stores `recoveriesPerTurn: 2`, which is also the default. So a second test writes 3 at the stored key of a copy and expects 3 back. This proves that the restore reads the key and does not fall back to a default.
  timestamp: 2026-09-26T06:43:12.520793+00:00
- actor: claude-code
  id: 01m3e7jn2t8v48wt1xkebxzqxn
  text: |-
    Proof that the tests can fail (each mutation reverted afterwards):
    - The `startAnswerLimits()` call removed from the pump: `answerGetsItsLimitsAndTheNextAnswerStartsFresh` fails (6 issues).
    - A reset added at the start of each submission (`runWatchedModelCall`): `continuationKeepsTheLimitsOfItsAnswer` fails (8 issues).
    - The `CodingKeys` mapping removed: all 3 `StoredRecoveriesKeyTests` fail (4 issues).
    - The overflow retry is a parameter, not stored state, so no small mutation can make it survive across answers. `eachAnswerGetsItsOwnOverflowRetry` pins the behavior (calls 1 and 3 overflow; 4 calls, 2 replies).
    Helper changes: `RepeatingReasoningModel.Executor.writeReasoning` and `CeilingStopCompactionModel.Executor.send` are now internal (were private) so the new `AnswerLimitsModel` reuses them. `[SessionEvent].repetitionStops` added to `SessionEventCollection.swift`. `ScriptedOverflowBackend` in AutoCompactionTests got an `overflowingCalls` schedule.
    Not changed: `generation-queue.md` 5.6 still says the fixture is "untracked"; it is tracked since f87c7e8.

    ### implement — changed
    - evidence: Sources: RepetitionDetection.swift, RoutedSessionActorPump.swift, RoutedSessionActorRepetitionWatch.swift, TranscriptEvent.swift, TokenBudget.swift, RoutedSessionActorTurnExecution.swift. Tests: new AnswerLimitsTests.swift, StoredRecoveriesKeyTests.swift, Helpers/AnswerLimitsModel.swift; changed AutoCompactionTests, RepetitionStopTests, SessionTreeRestorationTests, TranscriptEventSchemaTests, TranscriptReconstructionTests, SessionChokepointTests, Helpers/{CeilingStopCompactionModel,RepeatingReasoningModel,SessionEventCollection}.swift. `swift test`: 1463 + 14 + 19 = 1496 passed (was 1490; +6 new), 2 known issues as before. swiftpm-testing-helper --repetitions 20 over 13 suites (recording, compaction, repetition, overflow; 159 tests): passed. IntegrationTests `swift build --build-tests`: complete. Only warning: the known mlx "missing creator" line.
    - next: /review
  timestamp: 2026-09-26T06:48:54.106457+00:00
- actor: claude-code
  id: 01m3e91nfw374krykxk82aye91
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (abc9666). 3 findings: Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:95, Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:139, Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:248 (code-hygiene/magic-numbers-swift).
    - next: Replace the magic numbers in AnswerLimitsModel.swift with named constants. Do this for all magic numbers in the file, not only the three lines. Then run the tests and review again.
  timestamp: 2026-09-26T07:14:34.620360+00:00
- actor: claude-code
  id: 01m3e92sgg41yazy262vsfwx3z
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 20 files (startAnswerLimits; renames to answer; stored key kept)
    - test: green — swift test, 1496 passed (1463+14+19), 0 failed, 0 skipped; 7 recording and compaction suites 3 extra runs clean; all products and IntegrationTests build clean
    - commit: abc9666
    - review: findings — Helpers/AnswerLimitsModel.swift:95, :139, :248
  timestamp: 2026-09-26T07:15:11.504374+00:00
- actor: claude-code
  id: 01m3e96zpy9kwhyt7pen9ea2p7
  text: |-
    Review fix (implement, iteration 2): I replaced each magic number in `Helpers/AnswerLimitsModel.swift` with a named constant.
    - `AnswerLimitsModel.ceilingStopTokensIn = 400` now feeds `ceilingStopUsage`. The doc comment now names the budget of the fixture and not raw values.
    - `AnswerLimitsModel.repeatingHoldSeconds = 5` now feeds `repeatingHold`.
    - `AnswerLimitsSessionFixture.budgetLimit = 1_000`, `budgetTrigger = 0.8`, `budgetTarget = 0.5` now feed `budget`.
    - `AnswerLimitsSessionFixture.recoveriesPerAnswer = 1` now feeds `detection`. swiftlint allows 1, but I named it because the value is a limit that the tests rely on.
    - swiftlint 0.65.1, only rule `no_magic_numbers`, `allowed_numbers: [0, 1, -1, 100]` (the rule config of the validator), over AnswerLimitsModel.swift, AnswerLimitsTests.swift and StoredRecoveriesKeyTests.swift. Before: 5 violations, all in AnswerLimitsModel.swift (lines 95, 139, and 248 x3). After: 0. The two test files had 0 before: their numbers are already named constants (`fixtureRecoveries`, `fixtureContext`) or 0 and 1.
    - The repo has no `.swiftlint.yml`, so I used a scratch config with only this rule.
    - No test and no assertion changed.
  timestamp: 2026-09-26T07:17:28.926606+00:00
- actor: claude-code
  id: 01m3e9744kfcd5e176c0g1kswt
  text: |-
    ### implement — changed
    - evidence: 1 file: Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift. swiftlint no_magic_numbers over the 3 new test files of abc9666: 5 before, 0 after. `swift test`: 1463 + 14 + 19 = 1496 passed, 2 known issues as before, 0 failed; the only warning is the known mlx "missing creator" line. `swift test --skip-build --filter 'AnswerLimitsTests|StoredRecoveriesKeyTests'` 3 extra times: 5 tests in 2 suites passed each time. The 3 findings are `- [x]`.
    - next: /review
  timestamp: 2026-09-26T07:17:33.459157+00:00
- actor: claude-code
  id: 01m3e9kk3fjttx612wdwfwz6nb
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 0604412). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. The engine reviewed 1 file. The .reviewignore rule excluded 2 .kanban files.
    - prior findings: all 3 items of "Review Findings (2026-09-26 01:56)" are checked. The commit replaced each magic number with a named constant: `ceilingStopTokensIn` (400), `repeatingHoldSeconds` (5), and `budgetLimit`, `budgetTrigger`, `budgetTarget`, `recoveriesPerAnswer` in `AnswerLimitsSessionFixture`.
    - next: none. The task moved to done.
  timestamp: 2026-09-26T07:24:21.999830+00:00
- actor: claude-code
  id: 01m3e9mt39fnd4x6m9f4znz6td
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 test helper (named constants; swiftlint no_magic_numbers 5 to 0)
    - test: green — swift test, 1496 passed (1463+14+19), 0 failed, 0 skipped
    - commit: 0604412
    - review: clean — 0 findings
  timestamp: 2026-09-26T07:25:01.929658+00:00
depends_on:
- 01M3CYK7FSPBXGC7NWD3QX0MPT
position_column: done
position_ordinal: ffffff8e80
title: Count recoveries and compaction stops for each answer, and keep the stored key recoveriesPerTurn
---
## Why

Three limits reset "for each turn" now: `compactionYieldsStopped` and `repetitionWatch.recoveriesThisTurn` (both reset in `beginTurn()`, `Session/RoutedSessionActorTurnGating.swift`), and the one overflow retry of `runTurnAttempt`. After task ^3qx0mpt there is no turn. The unit that these limits guard is the chain of submissions that makes one final answer. The public setting `RepetitionDetection.recoveriesPerTurn` is also written in `session.json` (`configuration.repetitionDetection.recoveriesPerTurn`), so old recordings must still load. Design: `generation-queue.md`, sections 5.5 and 5.6.

## What to do

1. Reset `compactionYieldsStopped`, the count of repetition recoveries and the overflow-retry permission when the pump starts the first submission of a new answer. Do not reset them for a continuation submission of the same answer.
2. Rename the Swift property `RepetitionDetection.recoveriesPerTurn` to `recoveriesPerAnswer` (and `defaultRecoveriesPerTurn`). Keep the key on disk: add a `CodingKeys` case `recoveriesPerAnswer = "recoveriesPerTurn"`. Do not change the key and do not bump `schemaVersion`.
3. Rename the Swift name `TranscriptEvent.isFailedTurnClose` to `isFailedAnswerClose`, with no change of the bytes on disk.
4. Add a load test over the fixture recording `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/` (untracked now; declare it as a test resource in `Package.swift`, which also removes the build warning "found 2 file(s) which are unhandled"). If that directory is not in the tree when this task starts, write a new fixture with `recoveriesPerTurn: 2` in `session.json`.

## Acceptance Criteria

- [x] A test: an answer that needs two compaction yields and one repetition recovery gets them, and the next answer starts with fresh limits. <!-- AnswerLimitsTests.answerGetsItsLimitsAndTheNextAnswerStartsFresh; overflow retry for each answer: AutoCompactionTests.eachAnswerGetsItsOwnOverflowRetry -->
- [x] A test: a continuation submission does not reset the limits of its answer. <!-- AnswerLimitsTests.continuationKeepsTheLimitsOfItsAnswer -->
- [x] A test: the fixture recording with `recoveriesPerTurn` loads, and its value reads back as `recoveriesPerAnswer`. <!-- StoredRecoveriesKeyTests.recordingWrittenBeforeTheRenameLoads, StoredRecoveriesKeyTests.storedValueIsTheValueTheRestoreReads -->
- [x] A test: a session written now still writes the key `recoveriesPerTurn` in `session.json`. <!-- StoredRecoveriesKeyTests.sessionWrittenNowWritesTheStoredKey -->
- [x] The build has no "unhandled file" warning. <!-- Package.swift excludes Fixtures (f87c7e8); `swift build --build-tests` shows only the known mlx "missing creator" line -->
- [x] Full `swift test` green, 0 new warnings. <!-- 1463 + 14 + 19 = 1496 passed -->

#generation-queue

## Review Findings (2026-09-26 01:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:95` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:139` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerLimitsModel.swift:248` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
