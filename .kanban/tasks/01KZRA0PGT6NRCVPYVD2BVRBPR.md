---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kztg1vz9eqmbxhb791g4wrk9
  text: |-
    Research complete. Findings:

    - The bug is in recordTranscriptDelta (RoutedSessionActorRecording.swift). It selects the FIRST `.prompt` partial with `diffPartials.firstIndex { $0.kind == .prompt }`. When priming is on, the diff is [.prompt (seed), .toolCalls, .toolOutput, .prompt (real), .response]. The first `.prompt` is the priming seed. The composed preamble text goes to the real prompt, but the segments go to the seed. The two views drift.
    - Rule selected: attach to the LAST `.prompt` partial. Reason: a turn submits exactly one prompt of its own, and the priming seed entries always come before it in the diff. A text-match rule is weaker: the recorder does not hold the composed prompt at that point, and redaction can change the text.
    - The `entry == nil` edge: `appendingOperationEventSegments` returns the partial unchanged when `partial.entry == nil`, but `pendingEventsAttached` stays true. The differ always sets `entry`, so the shape is not reachable end to end. Plan: extract one internal static function that selects the target, attaches the segments, and reports if the attachment occurred. A unit test can then supply a hand-built partial with `entry == nil` and assert `attached == false`. The chokepoint requeues on `attached == false` (finishTurnAndRequeueIfUnattached); the test pendingEventSurvivesThrowBeforeAnyTranscriptAppend already proves that path.
    - Test plan (TDD): (1) end-to-end test in DiscoveryPrimingTests — primed turn, non-empty outbox, assert the custom segments and the preamble text sit on the same recorded prompt event, and the seed prompt carries no custom segment; (2) unit test on the new seam for the `entry == nil` shape — assert `attached == false` and partials unchanged, so the chokepoint requeues instead of drops.
  timestamp: 2026-08-12T08:05:07.177030+00:00
- actor: claude-code
  id: 01kztgw57dfw9h0h1c2krepffx
  text: |-
    Implementation complete, TDD sequence:

    1. RED: added the end-to-end test primedTurnAttachesPendingEventSegmentsToTheRealPrompt (DiscoveryPrimingTests.swift). It failed for the correct cause: the custom segment was not on the real prompt entry.
    2. Refactor: extracted the attach logic into one internal static function, RoutedSessionActor.attachingPendingEventSegments(events:to:), with the old behavior kept (first `.prompt`, dishonest attached flag). This made the `entry == nil` shape testable.
    3. RED: added the unit test promptPartialWithoutEntryReportsUnattached (PendingEventInjectionTests.swift). It failed: attached was true for a `.prompt` partial with no entry payload.
    4. GREEN: changed the function to (a) select the LAST `.prompt` partial — the rule is documented on the function: a turn submits exactly one prompt of its own, and priming seed entries come before it in the diff — and (b) report attached = false when no `.prompt` partial exists or the selected one has no entry payload. Both tests then passed.

    Notes:
    - The `entry == nil` shape is not reachable end to end (the differ always sets `entry`), so the requeue assertion for that shape is at the seam: the test proves attached == false and the partials come back unchanged. The chokepoint requeues on attached == false (finishTurnAndRequeueIfUnattached), and the existing test pendingEventSurvivesThrowBeforeAnyTranscriptAppend proves that requeue path end to end. Together the two tests show the events are requeued, not dropped.
    - Updated the stale doc references: recordTranscriptDelta's pendingEvents and Returns sections, and the drain-on-turn comment in generate() now name attachingPendingEventSegments and the last-prompt rule.
    - No public API change. The old private helper appendingOperationEventSegments is replaced by the new internal function.

    Verification: one full `swift test` run. Result: 864 + 27 + 24 tests passed, 0 failures. Known accepted noise only (BoundedWait known issue, mlx-swift "missing creator" warning).
  timestamp: 2026-08-12T08:19:28.621832+00:00
- actor: claude-code
  id: 01kztgwh3gewhecwcfzy52awcw
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift (doc comment only), Tests/FoundationModelsRouterTests/DiscoveryPrimingTests.swift, Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift; swift test: 864 + 27 + 24 tests passed, 0 failures
    - next: /review
  timestamp: 2026-08-12T08:19:40.784592+00:00
- actor: claude-code
  id: 01kzth6fn1d5mkepdjva4ca7hc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings (8 validators attempted, 0 failed)
    - next: none, task is done
  timestamp: 2026-08-12T08:25:06.977118+00:00
- actor: claude-code
  id: 01kzth76tbzf1xs2wd0xd91p5d
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files, the attach logic targets the last .prompt partial and reports honestly
    - test: green — swift test, 864 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 38a4593
    - review: clean — 0 findings, scope HEAD~1..HEAD
    - result: the task is in done
  timestamp: 2026-08-12T08:25:30.699076+00:00
position_column: done
position_ordinal: ff9480
title: Attach pending-event segments to the real prompt when priming is on
---
## Problem

Pending outbox events are drained early in the turn (Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:122), before discovery priming reseeds the backend (:209). The recording chokepoint then attaches the drained events' `OperationEventSegment`s to the FIRST `.prompt` partial in the diff (Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:264). When priming is on, that first prompt is the synthetic discovery prompt, not the turn's real prompt. The flattened preamble text lands on the real prompt, and the structured segments land on the priming entry. `OperationEventSegment`'s own contract says the two views "never drift apart" (Sources/FoundationModelsRouter/Session/OperationEventSegment.swift:48-53). They drift here. No test drives priming together with a non-empty outbox.

A related unguarded edge: `pendingEventsAttached` is computed as true when a prompt index was found (:303), but `appendingOperationEventSegments` returns the partial UNCHANGED when `partial.entry == nil` (:323). In that shape the events would be neither persisted nor requeued. It is unreachable today (the differ always populates `entry`), but nothing guards it.

## Proposed solution

1. Select the augmentation target as the LAST `.prompt` partial in the diff (the turn's own prompt always follows the priming seed), or match the prompt whose flattened text equals the composed prompt. Choose one rule and document it.
2. Make the attachment claim honest: compute `pendingEventsAttached` from whether augmentation actually happened, so an `entry == nil` partial triggers a requeue instead of a silent drop.

## Acceptance

- A test drives a primed turn with a non-empty outbox and asserts the `OperationEventSegment`s sit on the turn's real `.prompt` entry — the same entry that carries the preamble text.
- A test covers the `entry == nil` shape and asserts the events are requeued, not dropped. #transcript