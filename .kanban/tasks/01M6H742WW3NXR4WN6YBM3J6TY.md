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
- actor: claude-code
  id: 01m6h9d5k3dv3sndqade0wa09h
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 5 findings (5 confirmed, 1 refuted). Sources/FoundationModelsRouter/Recording/OrphanRunScan.swift:156, Sources/FoundationModelsRouter/Recording/Sinks.swift:143, Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:339, :496, :610
    - next: implement the 5 open findings, then review again
  timestamp: 2026-11-03T18:05:40.323367+00:00
- actor: claude-code
  id: 01m6h9j07ptkc2832pwgjx9vs5
  text: |-
    ### implement — changed
    - evidence: 6 files — OrphanRunScan.swift, Sinks.swift, CrashRestoreReviewTests.swift, WriteAheadToolCallTests.swift, Helpers/TranscriptEntrySegments.swift; full swift test passed (2339 tests in 282 suites, plus 38 and 19), no warnings
    - next: review
  timestamp: 2026-11-03T18:08:18.678260+00:00
- actor: claude-code
  id: 01m6h9pcew46zq8n89w4eyn2tw
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 1 finding (1 confirmed, 0 refuted). Sources/FoundationModelsRouter/Recording/Sinks.swift:130. The five earlier findings are fixed and checked: OrphanRunScan.swift (one lostTerminal factory), Sinks.swift (one appendDroppingFailure call), toolOutputTexts (shared helper), toolOutputIDs (hoisted to Helpers/TranscriptEntrySegments.swift), ObjectBox (swiftlint disable with invariant).
    - next: the implementer fixes the open finding in the 2026-11-03 12:08 section.
  timestamp: 2026-11-03T18:10:42.268376+00:00
- actor: claude-code
  id: 01m6h9ywt00xdwebskaq741r1a
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 2 findings (2 confirmed, 2 refuted): Sources/FoundationModelsRouter/Recording/Sinks.swift:186, Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:530. The prior finding at Sinks.swift:130 is not raised again.
    - next: fix the two open findings, then review again.
  timestamp: 2026-11-03T18:15:21.152250+00:00
- actor: claude-code
  id: 01m6ha6ha9pe0d6ybdhqgstqs5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD, 0 findings (0 confirmed, 0 refuted). Both findings of the 12:14 pass (Sinks.swift:186 and CrashRestoreReviewTests.swift:530) are fixed and not raised again. All prior review findings are checked.
    - next: none. Card moved to done.
  timestamp: 2026-11-03T18:19:31.529034+00:00
position_column: done
position_ordinal: ffffffffe480
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

## Review Findings (2026-11-03 12:01)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 17 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/OrphanRunScan.swift:156` `reuse/reuse` — `lostTerminal(withoutEventOf:)` builds a `.completed` / `.lost` `OperationEvent` by hand. The same construction already exists in `lostTerminalEvents()`, which builds the lost terminal for a run that wrote events. The two copies can drift apart, for example if the lost terminal shape changes in one place only. Add one private factory, for example `lostTerminal(tool:op:correlationID:detail:)`, that returns the `.completed` / `.lost` event. Have `lostTerminalEvents()` and `lostTerminal(withoutEventOf:)` both call it with their own `op` and `detail`.
- [x] `Sources/FoundationModelsRouter/Recording/Sinks.swift:143` `reuse/reuse` — `appendMarker` repeats the best-effort append call that `append` already makes. It passes the same `appendLine`, the same `RouterTelemetry.makeLogger(.recording)` logger, and the same `JSONLAppend.appendDroppingFailure` call. Only the failure message, the extra `toolCallId` metadata, and the counter differ. Two copies of this call can drift apart, for example in how the logger or the target file is chosen. Extend the existing path instead of copying it. Give `append` (or a private helper it calls) parameters for the failure message and the extra metadata, and let it return the `Bool` result. `append` can then call the counter on a `false` result when the marker path needs it. Keep one call to `JSONLAppend.appendDroppingFailure` in the file.
- [x] `Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:339` `reuse/reuse` — toolOutputTexts(of:) rebuilds the text of each .toolOutput entry. An existing helper already does this on a transcript, so this copy repeats the same logic and can drift from it. Call ScriptedToolCallingModel's toolOutputTexts(in:) with `await session.transcript` and remove the local copy, or move the helper to a shared test support file if the nested location is awkward to reach.
- [x] `Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:496` `reuse/reuse` — toolOutputIDs(in:) collects the output ids of .toolOutput entries. The same function already exists in another test suite, so there are now two copies of one mapping. Move one shared helper into a common test support file, make both suites call it, and remove the duplicate. A near-match in a `private` member is not a reuse path until it is hoisted.
- [x] `Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:610` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.

## Review Findings (2026-11-03 12:08)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/Sinks.swift:130` `completeness/invariant-propagation` — The new doc comment says a failed tool-call marker write is never silent: the error log names the call id and a counter counts the loss. That holds only for a write that reaches JSONLAppend. When the recording root is held by another live owner, `append` returns at `guard ensureRootOwnership() else { return }` (line 109). The refusal is logged by `ensureRootOwnership` (lines 168-170) with the generic message and no call id, and `recordDroppedToolCallMarker()` is not called. A dropped tool-call marker on this path is silent, so a restore after a crash in that call finds no open call and no counter records the loss. The fix is applied at one drop site and not at its sibling. When the event is a tool-call marker (`event.toolCallStartedID != nil`) and `ensureRootOwnership()` refuses, log the refusal with the call id in the metadata (use `failureMetadata(of:markedCallID:)`) and call `RouterMetrics().recordDroppedToolCallMarker()`. Alternatively, narrow the doc comment at Sinks.swift:127-134 so it does not claim the guarantee for the ownership-refusal path. Add a test where a second owner holds the root and a marker is refused, then assert the call-id log and the counter.

## Review Findings (2026-11-03 12:14)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/Sinks.swift:186` `reuse/reuse` — logRefusal repeats the drop-log and counter logic that append already runs for a failed write. It picks the same message by the same nil-check on markedCallID, and it makes the same recordDroppedToolCallMarker call. Two copies of this policy can drift apart, for example if one later gains a field or a different message. Route the refusal through the same drop path that appendDroppingFailure uses, or move the marker-or-event message choice and the counter call into one private helper that both paths call. Pass only the wording that differs.
- [x] `Tests/FoundationModelsRouterTests/CrashRestoreReviewTests.swift:530` `reuse/reuse` — The new refusedMarkerIsLoggedAndCounted test is a near-copy of failedMarkerWriteIsLoggedAndCounted. The two bodies share the same temp directory, the same TelemetryCapture run, the same expectLogged call on the tool call marker and call id, and the same counter assertion. Only the recorder setup and the failure cause differ. Each later change to the marker assertion must be made in both tests. Extract a helper that takes a recorder and asserts the marker is logged with its call id and counted once, for example `expectMarkerDropped(by recorder:)`. Call it from both tests, and keep the recorder setup in each test.
