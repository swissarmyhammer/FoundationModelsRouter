---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
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