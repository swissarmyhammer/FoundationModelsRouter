---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hd810n0j9cf943knkgvaf0
  text: |-
    ### implement — changed
    - New kind: TranscriptEvent.Kind.promptStarted (public). The pump writes it when it takes user mail: in runFirstSubmission (first submission) and in the continuation branch of runSubmission (mail that joins a running answer). A queued mail has no marker. One append call per take.
    - The marker holds the text of the user messages and one mailDelivered record for each mail (id and content). TranscriptEvent.mailRecords skips the marker. TranscriptEvent.takenMail reads it.
    - Restore: OpenPrompts.folding. A mail is covered by a later .prompt entry that delivers it, or by a later cancelled or answerEnded record. A lost record does not cover. An open mail becomes a .prompt entry at the place of the marker. Open tool calls come after it. ContextRenderer runs OpenPrompts before OpenToolCalls. effectiveTranscript now also reads .promptStarted and .mail events.
    - FirstPromptReader stops at the first .prompt or .promptStarted. A marker after the fork cut is not read.
    - forkPrefix drops a .promptStarted marker after the last kept entry, like .toolCallStarted.
    - Drop policy: WriteAheadMarker (new) names the marker; same single policy helper in Sinks. New log key mailId, new counter promptMarkerDropped, RouterMetrics.recordDroppedPromptMarker().
    - Skip lists: TranscriptEntryMapper, SessionObserver (2), RoutedSessionActorRecording emitSessionEvents.
    - Tests: new PromptWriteAheadTests (27 tests). Existing tests that assert exact event kinds now list .promptStarted. Full swift test: 2373 tests passed.
    - Known limit: a fork cut at the end of a restored parent that still has an open prompt keeps no open prompt on a later restore of the fork (the cut counts entry events, as for open tool calls).
    - Note: SessionAnswerTests "the answer carries the diff's tool calls ..." failed in 2 of 3 full runs with the two parallel calls in swapped order, and passed alone. The order of parallel tool starts is a race that this change does not touch.
  timestamp: 2026-11-03T19:12:46.101862+00:00
position_column: review
position_ordinal: '80'
title: 'Write-ahead of the prompt that starts a submission: a crash must not lose the user message in flight'
---
## What
HIGH priority (coordinator, 2026-11-03). The Agents session found that a child cut before its first answer has NO recorded first prompt (`RecordedChild.firstPrompt` is nil). A child run is one submission with many tool passes. Transcript entries are written at the END of the submission (`finishSubmission`, `Session/RoutedSessionActorRecording.swift`). After a crash the typical interrupted child has an empty transcript and its task prompt is lost, so a restored child would work blind. The same holds for any session: the user message that starts the submission in flight at a crash is lost.

## Design (same method as the tool call marker, card 01M6GK7RHHHC6B6QMJ25FT1QDT)
1. New small partial kind `.promptStarted`, with the mail id and the message content. It is written durably when the submission TAKES the mail, before the model runs. A mail that is only queued (not yet taken) is NOT recorded as started.
2. Restore folds it: a `.promptStarted` marker that no later transcript entry covers (the prompt entry of that mail) becomes the final user message of the reconstructed transcript (awaiting its answer), with the open tool calls and their placeholders AFTER it (`Recording/OpenToolCalls.swift`, `TranscriptReconstruction`). Decide how a later `.prompt` entry covers a marker (by mail id; check how `attachingDeliveredMailRecords` and the mail records carry the id).
3. No duplicate: when the end-of-submission diff later records the same message, the marker is dropped by reconstruction (as `.toolCallStarted` is).
4. `firstPrompt` (`RecordedChild.firstPrompt`, `RouterSessionDirectory.firstPrompt(of:)`, `Recording/FirstPromptReader.swift`) reads the prompt from this marker when the transcript has none. Keep it a streaming read that stops at the first prompt or marker.
5. The marker write failure is visible (log with the mail id, counter), as for the tool call marker (`Sinks.swift`). Other readers (observer, entry mapper, forkPrefix) skip the new kind, as they do for `.toolCallStarted`; check `forkPrefix` drops a marker after the last kept entry.
6. A suspended session (suspend()) and a normal close: no change.

## Acceptance Criteria
- [ ] Crash in the middle of the first submission, restore: the transcript ends with the user message (then open tool calls and placeholders), and `firstPrompt` is not nil.
- [ ] A clean run records the prompt once (no duplicate in the reconstruction).
- [ ] A queued mail that is not yet taken is not recorded as started.
- [ ] A marker write failure is logged and counted; the submission still runs.
- [ ] No change in the behavior of an existing clean session.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/PromptWriteAheadTests.swift`: crash in the first submission, restore, transcript tail, firstPrompt; clean run no duplicate; queued mail; fork of a restored parent. Full `swift test` once.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents