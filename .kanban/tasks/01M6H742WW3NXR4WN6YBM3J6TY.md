---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6h8z1cxjv2g3byaayppnr0r
  text: |-
    Item 13 result (verified with tests): after a restore, the next end-of-submission diff DID record a folded placeholder as a real entry. Case: a crash in the first submission, before the first diff. The recording then holds only the write-ahead markers, so the seed has two entries (the folded toolCalls and the placeholder toolOutput) and the backend adds a leading instructions entry for its tools. The restore set persistedEntryCount to the seed count, so the baseline was one entry short and the diff recorded the placeholder toolOutput as new (seq after the restore, entry id = call id). The "open-calls-..." toolCalls entry was not recorded. Fix: persistedEntryCount is now the count of entries the backend really holds (SessionTreeRestoration). Second case: a real toolOutput for a started call that has no toolCalls entry gave two outputs for the call (the placeholder and the real one). Fix: OpenToolCalls.folding makes the toolCalls entry from the marker and no placeholder when the recording holds a toolOutput with the id of the call. Both cases have a test in CrashRestoreReviewTests (both failed first).

    Item 10 note: the journal did get the completed event in the forced interleaving even with the old code. What was wrong: the claim left openClaims before the post, so close() found no claim, did not wait for the post, and could return before the terminal event was in the journal (an orderly quit then loses it). Fix: the claim stays in openClaims (isCompleting) until the post returns; close takes it, and its lost terminal waits behind the post in the journal chain; the journal admits one terminal for each run. A gate test (recorder gate, no sleeps) checks that the claim is held while the terminal is on its way, and that the interleaving of close and completion leaves exactly one terminal event.
  timestamp: 2026-11-03T17:57:57.277246+00:00
- actor: claude-code
  id: 01m6h91pzeds29pk3fvnd5jzt9
  text: |-
    ### implement — changed
    - evidence: full swift test run once: 2339 tests, 1 failure (my own edit of a WriteAhead test, a text list that holds the run-event entry); fixed, WriteAheadToolCallTests rerun: 27 of 27 pass. New file CrashRestoreReviewTests.swift: 15 tests, all pass. Each new test failed first (item 10: claim-held test failed on the old code; items 11, 12, 13, 14 failed on the old code).
    - items 10 to 14 done. Items 12 and 13: see below. Public API change: OpenToolCalls (internal) constants renamed: interruptedOutput removed; runningOutput, lostOutput, endedOutput, unrecordedOutput. The 4th text (endedOutput) is added by me: a call whose run has a terminal event must not get the "not recorded" text, so it says the run ended and the result is in a run message. Undecided: wording of the four texts (STE). No public type changed; RoutedSession.completeClaimedRun doc and SessionTreeRestorationError.runNotClaimable doc changed (a run with no event is claimable with an unended child that holds its token). New metric name toolCallMarkerDropped and log key toolCallId (internal vocabulary).
    - next: review
  timestamp: 2026-11-03T17:59:24.910658+00:00
position_column: review
position_ordinal: '80'
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