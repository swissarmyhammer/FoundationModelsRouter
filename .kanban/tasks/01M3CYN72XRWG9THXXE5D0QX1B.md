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
depends_on:
- 01M3CYK7FSPBXGC7NWD3QX0MPT
position_column: doing
position_ordinal: '80'
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