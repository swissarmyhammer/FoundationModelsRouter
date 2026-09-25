---
assignees:
- claude-code
depends_on:
- 01M3CYK7FSPBXGC7NWD3QX0MPT
position_column: todo
position_ordinal: '9580'
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

- [ ] A test: an answer that needs two compaction yields and one repetition recovery gets them, and the next answer starts with fresh limits.
- [ ] A test: a continuation submission does not reset the limits of its answer.
- [ ] A test: the fixture recording with `recoveriesPerTurn` loads, and its value reads back as `recoveriesPerAnswer`.
- [ ] A test: a session written now still writes the key `recoveriesPerTurn` in `session.json`.
- [ ] The build has no "unhandled file" warning.
- [ ] Full `swift test` green, 0 new warnings. #generation-queue