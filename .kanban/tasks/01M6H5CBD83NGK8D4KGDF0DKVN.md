---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6h6dazmn87zg91hemebmf4b
  text: |-
    ### Results of the Router tests (normal close, real OperationTool on a real run plane)
    Both writers (the sweep of the close, and the body of the run) write the terminal event. The first write wins, so a body that reacts to the cancel gets one of two outcomes. Both were seen.
    - Body swallows the cancel and returns text: cancelled (sweep won) or succeeded (body won).
    - Body throws CancellationError: cancelled (sweep won) or failed (body won). AnyOperation wraps the error in OperationError.executionFailed, so the run plane does not see a CancellationError.
    - Body throws a LostRunError: cancelled (sweep won) or failed (body won), for the same reason. The outcome is never lost.
    - Body that ignores the cancel until the sweep wrote its terminal: cancelled (deterministic), past the grace and inline.
    ### Implementation
    RoutedSession.suspend() (nonisolated) and RouterSessionDirectory.suspendLiveSessions(). After suspend the journal refuses every terminal event (claimJournalWrite), completeClaimedRun returns false, and close leaves claims open (no lost). Normal close() is unchanged. No change in Extras.
    ### implement — changed
    - evidence: full swift test: 2319 tests passed (plus 38 and 19 in other runs), zero failures. New tests: 8 test functions, 13 cases in Tests/FoundationModelsRouterTests/SuspendingCloseTests.swift.
    - next: /review
  timestamp: 2026-11-03T17:13:20.116506+00:00
position_column: review
position_ordinal: '8180'
title: A tool run that the host cancels for a shutdown must not be journaled as succeeded
---
## What
Found by the Agents host session with the real Router: after `runner.stop()` and a close of the root session, the root journal holds the `start agent` call as completed(succeeded) with the text "Agent ... was cancelled.". A restore then treats the run as done (not orphaned), so the run is not restored.

## Facts (read in the code, not run; `EXT` = FoundationModelsExtras checkout in `.build/checkouts`)
- Every background-mounted call is a run on `RunPlane` from its start (`BackgroundToolRunner.start`, Hosting/BackgroundToolRunner.swift:170-200). "Inline" and "past the settle grace" are the same run.
- The outcome is decided in Extras, not in the Router: `ToolRun.settle` / `outcomeAndDetail` (Hosting/ToolRun.swift ~110-186): returned text is `.succeeded`; `CancellationError` is `.cancelled`; a `LostRunError` is `.lost`; anything else `.failed`. The Router only journals the terminal (`Session/RoutedSessionActorRunJournal.swift:258`, `claimJournalWrite`, first write wins).
- `close()` (`Session/RoutedSessionActorClosing.swift:154-244`) cancels the answer, runs `runPlane.sweep()` in the drain (`Session/RoutedSessionActorDrain.swift:251`) and waits for the run bodies. For `OperationTool` there is no custom canceler, so the sweep writes `completed(cancelled)`, never `lost`.
- (1b) Race: for a call still inline, the body can settle by itself while the sweep waits. A body that swallows the cancel and returns text ("was cancelled.") can win the journal write as `succeeded`. Which writer wins depends on scheduling. NEEDS A TEST with a real run.
- `AnyOperation.run` (Operations/AnyOperation.swift:84-88) wraps every operation error in `OperationError.executionFailed(cause:)`. Nothing unwraps it, so an operation that throws `CancellationError` or a `LostRunError` ends as `.failed`. NEEDS A TEST.

## Answer to the host question
(1) Close the root first, stop the runner after: the sweep covers both the background run and the inline call. It writes `cancelled`, NOT `lost`. The inline case can still end `succeeded` if the body returns text first (race).
(2) No body can end as `lost` today through an OperationTool operation: returned text is always `succeeded`; thrown cancel/lost errors are wrapped and become `failed`.

## Decision (coordinator, final)
- No change to FoundationModelsExtras. No workaround in a BackgroundTool.
- A swept `lost` is a terminal event. The key is then no orphan, and the claim API (orphans only) cannot complete the ORIGINAL start-agent call after a normal quit.
- For an orderly quit of the process, the runs must stay open and restorable, as after a crash.
- The Router gets a SUSPENDING close: `suspend()` on the session, then `close()`. A directory-wide call suspends all live sessions.
  - It sweeps nothing and writes no terminal event for a run that is open.
  - It drops the outcome writes of tool bodies that end after the suspend. The cooperative cancel makes such a body return text, and that text must not win the journal write.
  - It leaves open claims open (no `.lost`).
  - The write-ahead `.toolCallStarted` marker keeps the transcript valid.
- A normal `close()` (what the user asks for, for example ACP session/close) keeps the current behavior: it cancels the work, and the outcome is cancelled.

## Do
- Tests first (`Tests/FoundationModelsRouterTests/SuspendingCloseTests.swift`), with a real run plane: a background run past the settle grace, and a call still inline. Suspend, reload from disk, `runStatuses(of:)` gives `.orphaned` for both, `claimingRuns` accepts both, and `completeClaimedRun` completes them.
- A body that swallows the cancel and returns text after the suspend does not become succeeded.
- A normal `close()` still gives completed(cancelled).
- The transcript stays valid after the restore.
- Write the results of the Router tests for the cases of this card (body that swallows the cancel, body that throws `CancellationError`, body that throws a `LostRunError` that `AnyOperation` wraps) as a comment on this card.

## Acceptance Criteria
- [ ] A test shows what the journal records for each case above.
- [ ] A run that the host suspends for a shutdown stays open in the journal, never `succeeded`.
- [ ] A restore treats such a run as an orphan.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents