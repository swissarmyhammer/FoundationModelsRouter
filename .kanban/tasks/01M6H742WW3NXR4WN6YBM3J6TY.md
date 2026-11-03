---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: 'Crash and restore review fixes: atomic claim completion, claimable run with no event, honest placeholders, no double records, visible marker failure'
---
## What
Independent crash and restore review of Router 29e7153a (ACP session; coordinator decisions, 2026-11-03). Five items in one card. Each item gets a failing test first.

### 10. completeClaimedRun versus close
`completeClaimedRun` removes the claim and then awaits the journal attach and the post. A concurrent `close()` in that await finds no claim, and the `completed` event goes to a closing outbox. The call ends with no terminal event and no `lost` event. Fix: make the completion atomic with respect to close (keep the claim until the event is journaled, or journal `lost` on the close path). Test with a forced interleaving (no sleeps, no time limits: use a gate).

### 11. A run with no event is not claimable
A run is `.orphaned` only after at least one progress, elicitation or message event. A crash after the write-ahead marker and before the first operation event leaves NO status, and the placeholder says "interrupted", so the model starts the agent a second time while the host also restores the existing unended child: duplicate work. Fix: at restore, for an open call with a `correlationID` (the completion token), look at the recorded children: if an UNENDED child exists whose `agentSpawn.parentToolCallId` equals that token, the placeholder says the run is still working and the call is claimable by that key even with no journal event (the claim API accepts a key with no status when such a child exists). Test: crash before the first event.

### 12. Honest placeholder texts
(a) a claimed orphan: "still working, the result will arrive as a message".
(b) an orphan that is NOT claimed (the restore journals a lost terminal): say the run was lost, not that it is working.
(c) a call with no run (an inline tool that may have finished before the crash): "its result was not recorded; it may or may not have run; check the state before you repeat a call that is not safe to repeat". NOT "call it again".
Write the texts in ASD-STE100 style. Tests for each case. Check the placeholder of the earlier claim card (OpenToolCalls.runningOutput / interruptedOutput).

### 13. No double records after a restore
Verify, and write the result on the card: after a restore, the next end-of-submission diff must not record the folded placeholder entries ("open-calls-...") as real transcript entries, and a real `toolOutput` recorded for a started call without its `toolCalls` entry must not yield two outputs. Test both. Fix if a test fails.

### 14. Marker write failure must be visible
`appendDroppingFailure`: if the `toolCallStarted` marker cannot be written, the failure must be visible (a logged error with the call id, and a counter), not silent. Do not block the tool. F_FULLFSYNC and directory fsync are NOT needed: the requirement is a process crash and an orderly quit, not power loss. Say so in a comment in the code.

## Acceptance Criteria
- [ ] Item 10: a forced interleaving of close and completeClaimedRun leaves a terminal event (completed or lost) in the journal.
- [ ] Item 11: a crash before the first event leaves a claimable key when an unended child with that token exists; the placeholder says it is working.
- [ ] Item 12: the three placeholder texts are honest, one test each.
- [ ] Item 13: no folded placeholder is recorded as a real entry; no double output.
- [ ] Item 14: a failed marker write is logged with the call id and counted; the tool still runs.

## Tests
- [ ] New file `Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift` (or the existing suites). Run the full `swift test` once.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. Do after the relay follow-up and before the live tool-call events card. #subagents