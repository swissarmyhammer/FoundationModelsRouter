---
assignees:
- claude-code
depends_on:
- 01KZR9658E5CEVBK177RT024HY
position_column: todo
position_ordinal: '8e80'
title: Seed SessionProjection from a cold Transcript
---
## Problem

`SessionProjection` builds its rows only from live `SessionEvent`s, through `apply(_:)` (Sources/FoundationModelsRouter/Session/SessionProjection.swift). A restored session (`RoutedModel.restoreSessionTree`) has a full transcript history, but its projection starts empty. The UI shows a blank conversation for a session that has content. This looks broken to the user.

A second gap blocks the fix: `RoutedSession` does not expose its transcript publicly. A caller has no supported way to read the entries it must seed from.

## Proposed solution

1. Write a pure grouping function that maps `[Transcript.Entry]` to `[SessionProjection.TranscriptEntry]`:
   - `.response` entries become `.text` rows.
   - `.reasoning` entries become `.reasoning` rows.
   - `.toolCalls` and `.toolOutput` entries pair into `.toolCall` rows with `.completed` status and the output as summary. One `.toolCalls` entry can hold many calls; make one row per call.
   - A compaction boundary (`CompactionSegment`) becomes a `.compaction` row.
2. Pair each `.toolOutput` to its call by id equality first. When the id names no announced call, fall back to first-occurrence ordinal order — the same rule as `completedToolCallId(forOutputEntryId:dispatched:completed:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:433). Extract that pairing into one shared internal helper, so the live path and the cold path always agree.
3. Add `SessionProjection.seed(from:)` (or an initializer) that installs the rows. Live events applied after a seed must append normally.
4. Give the seed a transcript source. Choose one and document it: expose a read-only `transcript` accessor on `RoutedSession`, or seed from `TranscriptTree.effectiveTranscript(forSession:registry:view:)`.

## Acceptance

- Restore a recorded tool-turn session, seed a projection, and compare: the seeded rows must equal the rows a live projection produced during the original run, ids included (needs the stable-identity task).
- A live turn after a seed must append rows without duplication. #projection