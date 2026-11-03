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
- actor: claude-code
  id: 01m6he35x0ngf7s4v0na6hp90v
  text: |-
    ### review — findings
    - evidence: review sha 313b3890~1..313b3890. Engine: 2 findings (RouterMetrics.swift:204, duplication and reuse). Reviewer judgment on the known limits: fork cut at the end of a restored parent loses the open prompt = real defect, recorded; firstPrompt returns the text of a later cancelled mail = real defect, recorded; the SDK shape of a transcript that ends with an unanswered user prompt = cannot be checked offline, not a code defect, no finding. 4 open findings in the description.
    - next: implementer fixes the 4 items; re-review.
  timestamp: 2026-11-03T19:27:35.840420+00:00
- actor: claude-code
  id: 01m6hevpse3trb8216zpksxgey
  text: |-
    ### implement (review findings) — changed
    - Findings 1 and 2: one private helper recordDroppedMarker(label:) in RouterMetrics; both public entry points stay.
    - Finding 3: the cut of a fork now counts the entries of the folded history (new FoldedHistory). forkPrefix keeps an open prompt marker or open tool call marker when the cut counts its entries. A restored session starts its historyOrdinal at the folded count. Tool call markers use the same rule.
    - Finding 4: FirstPromptReader uses a PromptSearch that reads on after a marker until a record covers it. It shares coveredMailIDs(by:) and open(in:isCovered:) with OpenPrompts.
    - Note: the SDK shape of a transcript that ends with an unanswered user prompt is unverified offline.
    - Tests: full swift test, 2383 tests in 283 suites passed.
  timestamp: 2026-11-03T19:40:59.566409+00:00
- actor: claude-code
  id: 01m6hf30chjsxb6hsxttz7607p
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (f3a122cc). Engine: 2 findings (OpenPrompts.swift:83 duplication/duplication; OpenPrompts.swift:129 swift/fluent-usage). The four findings of the pass before are fixed: RouterMetrics duplication and reuse (one helper), fork cut loses open prompt (FoldedHistory), firstPrompt reads a cancelled mail (PromptSearch with the shared cover rule). No new finding on them. The SDK shape of a transcript that ends with an unanswered user prompt is unverified offline (note already on the card).
    - next: implementer fixes the 2 open items; re-review.
  timestamp: 2026-11-03T19:44:58.769396+00:00
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
## Review Findings (2026-11-03 13:16)

> Scope: `review sha 313b3890~1..313b3890` — reviewed the diffs only — lines this change added or modified. 36 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsRouter/Tracing/RouterMetrics.swift:204` `duplication/duplication` — recordDroppedPromptMarker repeats the body of recordDroppedToolCallMarker. Both functions build one Counter with a label and call increment() with no dimension. Only the metric label differs. A later change to one counter pattern can drift from the other copy. Extract one private helper, for example `recordDroppedMarker(named label: String)`, that builds the Counter and increments it. Have recordDroppedPromptMarker and recordDroppedToolCallMarker call it with their own label. Weigh the gain against the cost: each body is one line, so skip this change if you judge the pattern too small to be worth a helper.
- [x] `Sources/FoundationModelsRouter/Tracing/RouterMetrics.swift:204` `reuse/reuse` — recordDroppedPromptMarker() is a near-copy of recordDroppedToolCallMarker() (lines 198-200). Both build one Counter with a single metric label and call increment(). The only difference is the label. The second function repeats the first instead of sharing one helper that takes the label as a parameter. Two copies of the counting logic can drift apart. Add one private helper, for example `private func recordDroppedMarker(_ label: String)`, that builds the Counter and calls increment(). Make recordDroppedToolCallMarker() and recordDroppedPromptMarker() both call it with their metric name. Keep both public entry points, so the call sites in the recorder do not change.
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptTree.swift` `correctness/known-limit` — (reviewer judgment, a real defect.) A fork cut at the end of a restored parent that has an open prompt loses that prompt. The fork cut counts entry events on disk (`historyOrdinal` is `effectiveEvents.count`), and `forkPrefix` drops a `.promptStarted` marker after the last kept entry. But the live transcript of the fork is seeded from the parent backend, which holds the open prompt, and `persistedEntryCount` counts it as saved. So the fork answers a user message that its recording never holds: the next restore of the fork has a response with no prompt. This is the case that this card exists to prevent. Make the fork keep the open prompt of the parent: for example, count a marker with open mail at the end of the parent in the fork cut, or write the open prompt of a restored session as a `.prompt` entry.
- [x] `Sources/FoundationModelsRouter/Recording/FirstPromptReader.swift` `correctness/known-limit` — (reviewer judgment, a real defect.) `firstPrompt` stops at the first `.promptStarted` marker. When a later `.mail` record `.cancelled` or `.answerEnded` ends the mail of that marker, `OpenPrompts.folding` drops the marker, so the transcript has no such prompt. But `firstPrompt` returns the text of the cancelled mail. If a later submission has a real `.prompt` entry, `firstPrompt` still returns the cancelled text and not the first prompt of the transcript. The two readers disagree. Make `firstPrompt` apply the same cover rule as `OpenPrompts` (read on to find a delivery or terminal record of the mail of the marker), and add a test with a cancelled first mail.

## Review Findings (2026-11-03 13:41)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/OpenPrompts.swift:83` `duplication/duplication` — The new loop in OpenPrompts.lastCoveringIndex repeats the fold of OpenToolCalls.lastCoveringIndex. Both walk the events in order and store the index of the newest covering event under a key. Only the key source and the filter differ (mail ids from coveredMailIDs(by:) here, call ids from event.entry?.toolCalls there). The two copies can drift apart, and a later fix to one will be missed in the other. Extract one generic helper that takes the events and a closure returning the keys an event covers, for example `static func lastIndex<Key: Hashable>(in events: [TranscriptEvent], coveredKeys: (TranscriptEvent) -> [Key]) -> [Key: Int]`. Call it from OpenPrompts.lastCoveringIndex with `coveredMailIDs(by:)`. Keep the OpenToolCalls counterpart as a separate follow-up task, because it is outside this change. Do not edit it in this change.
- [x] `Sources/FoundationModelsRouter/Recording/OpenPrompts.swift:129` `swift/fluent-usage` — `static func open(in:isCovered:)` is a pure function with no side effect, but its name is an imperative verb. At a call site, `OpenPrompts.open(in: marker, ...)` reads as an action that changes state. Name the side-effect-free result as a noun phrase, for example `openMail(in:isCovered:)`, or `openMailOf(_:isCovered:)`. Keep the shape of the return value.
