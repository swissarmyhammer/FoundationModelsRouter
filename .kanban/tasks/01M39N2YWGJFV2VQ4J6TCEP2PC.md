---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39q0dg4wqcf2vcy9ynx9v68
  text: |-
    ### Research

    - `TranscriptTree.restoredUsageState(in:)` (Recording/TranscriptReconstruction.swift) reads `newestStampedUsage(in:)` (Compaction/TokenBudget.swift). `SessionTreeRestoration.swift` gives it `tree.effectiveEntryEvents(forSession:)`, which holds only entry kinds. So no `.generationCall` event reaches it.
    - The order in the journal of one attempt: the calls that ask for a tool are recorded at the tool open, BEFORE the entries of the attempt. `finishTurn` records the entries (the usage stamp goes on the last `.response`), and THEN records the last call. So the call that closes an attempt is always the first `.generationCall` after the stamped `.response`. The calls of the next turn that ask for a tool come after it.
    - The live counter (`finishTurn`) changes only when the diff of the attempt holds a `.response`. A failed turn, or a turn that a crash stopped, keeps the old counter. The tool-open calls of such a turn are in the journal, but no stamped `.response` follows them.
    - A fork: `performFork` mints the child id BEFORE it waits for the turn lock, so a time stamp cannot find the fork point. The cut is `forkedAtHistoryOrdinal` in entry-kind coordinates. The close call of the cut turn is after the cut-th entry and before the next entry of the parent. The tool-open calls of a later parent turn can also be in that gap.

    ### Decision (why, for the next agent)

    The card says "the newest `.generationCall` after the newest checkpoint". The user decision is: the restored counter must equal the live counter at the same point. In the normal flow the two are the same call. After a failed or crashed turn they are not: the newest call is a tool-open call of a turn that never set the live counter. So the reader reads the call that CLOSES the newest stamped `.response` after the newest checkpoint (the first `.generationCall` after it). With no stamped `.response` after the checkpoint: `tokensAfter`. With a stamped `.response` and no call after it (an old journal): the stamp, as before.

    For a fork, the tree gives the reader a new event list: entry kinds and `.generationCall` events, with the parent cut before its next entry after the cut. The reader reads only the first call after a stamped `.response`, so a later parent call in the gap is never read.
  timestamp: 2026-09-24T12:42:21.572831+00:00
- actor: claude-code
  id: 01m39q9cewkzg2hgmhqc43g6ds
  text: |-
    ### implement — changed
    - evidence: 7 files. Sources: Compaction/TokenBudget.swift (the top-level `newestStampedUsage` is replaced by `TranscriptEvent.turnUsageStamp` and `TranscriptEvent.generationCallCounts`), Recording/TranscriptReconstruction.swift (`restoredUsageState(in:)` reads the private `newestTurnRenderSize(in:)`: the first `.generationCall` after the newest stamped `.response` after the checkpoint; else `tokensAfter`; an old journal gives the stamp), Recording/TranscriptTree.swift (new `effectiveUsageEvents(forSession:)`, one worker `effectiveEvents(for:keeping:)`, `forkPrefix(of:entryCount:)` cuts the parent before its next entry after the cut, so a fork keeps the close call of the cut turn), Recording/SessionTreeRestoration.swift (the restore reads `effectiveUsageEvents`), Session/RoutedSession.swift (the `contextFill` doc). Tests: new Tests/FoundationModelsRouterTests/RestoredRenderCounterTests.swift (7 tests: tool loop of three calls gives the last call; checkpoint with no call after gives tokensAfter; old journal gives the stamp; a call of a later turn with no response is not read; the same after a checkpoint; the real journal of a live tool loop restores the live counter; a restored root and its restored fork from disk each report the live fill 0.37, with a later unfinished root call appended). GenerationCallUsageTests.swift reads `turnUsageStamp` in place of the removed function. SessionTreeRestorationTests.swift: one comment names the reader again.
    - RED: 4 of the 7 new tests failed before the fix (tool loop, later call, live journal, restore from disk). The 3 others hold the present rule, as the card asks. Mutation check: a fork cut that stops at the cut-th entry makes the fork test fail.
    - GREEN: `swift build --build-tests` clean (only the build-system line "missing creator for mutated node", which is not from the code); `swift test`: 1351 tests in 152 suites passed, 2 known issues (withKnownIssue in BoundedWaitTests and RealModelHarnessTests, not changed here).
    - Deviation from the card words, with the reason: the card says "the newest `.generationCall` after the checkpoint". The reader reads the call that closes the newest stamped `.response`, because a failed or stopped turn records tool-open calls that the live counter never reads. In the normal flow the two are the same call. A checkpoint with only such a call after it gives `tokensAfter`, as the live counter does.
    - next: review
  timestamp: 2026-09-24T12:47:15.420253+00:00
- actor: claude-code
  id: 01m39qf5wg2hrp9yjg7ak6ndhc
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (exit 0, no source warnings; the sole build-plan message, `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)`, is a pre-existing SwiftPM message about the mlx-swift dependency's resource bundle, not our source, and is documented in `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift`); `swift test` — 1351 tests in 152 suites passed, 1 test in 1 suite passed, 19 tests in 3 suites passed (1371 total, 0 failed, 0 skipped). The 2 "known issues" belong to the pre-existing `BoundedWaitTests` suite, which uses `withKnownIssue` on purpose to test the timeout path, and is unrelated to this task's diff; the suite still reports passed.
    - No failures and no fixes were needed. `RestoredRenderCounterTests.swift` (new for this task) ran in the suite "Restored render counter: the newest generation call, not the sum on the response stamp" and passed. A `diagnostics check working` call showed 3 stale SourceKit errors in `GenerationCallUsageTests.swift` for `turnUsageStamp` and `.endedInsideReasoning`; both symbols exist in source (`TokenBudget.swift`, `FinishReason.swift`), and a forced recompile of the three touched files (`touch` + `swift build --build-tests`) still built clean, so this was a stale LSP index, not a real error.
    - next: none. The build is clean.
  timestamp: 2026-09-24T12:50:25.296517+00:00
position_column: doing
position_ordinal: '80'
title: A restored session must restore the context counter from the newest generation call, not from the sum on the response stamp
---
## Problem

^tpsc0nf makes the context counter of a live session the size of the render: the fed and generated tokens of the newest generation call. It is not the sum of the calls of a tool loop.

A restored session does not follow this rule. `TranscriptTree.restoredUsageState(in:)` (Recording/TranscriptReconstruction.swift) reads `newestStampedUsage(in:)`: the `tokensIn`/`tokensOut` stamp on the newest `.response` event. That stamp is the SUM of the generation calls of the attempt (it is the cost of the attempt, and it stays the sum). So after a restore, `contextFill` reports the sum again, for example 1.877 in the run of ^tpsc0nf.

The tree gives `restoredUsageState` only entry events (`effectiveEntryEvents(forSession:)` reads `entryKindEvents`). The `.generationCall` events, which carry the usage of each call, are not in that list.

## Expected

- A restored session reads its counter from the newest `.generationCall` event after the newest compaction checkpoint: `tokensIn + tokensOut` of that call.
- With no such event after the checkpoint, the counter is the `tokensAfter` of the checkpoint.
- A journal with no `.generationCall` event (an old journal) keeps the present rule.

## Acceptance

- A test: a journal with a tool loop of three calls restores the counter of the last call, not the sum on the `.response` stamp.
- A test: a journal with a compaction checkpoint and no call after it restores `tokensAfter`.
- A test: an old journal with no `.generationCall` event restores the `.response` stamp as before.

## Source

Found during the implement step of ^tpsc0nf. That card does not name the restore path, so it is a separate task.