---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Keep the repeated part out of the render of a restored session after a repetition stop
---
## Problem

Task ^1hcwaqy removes the repeated part of a stopped call from the render that the model receives next, and the recorded transcript keeps the full entry. The session moves `persistedBaseline` to the trimmed render, as a compaction does.

A restore rebuilds the render from the record (`TranscriptTree.effectiveTranscript(forSession:)`). The record holds the full reasoning entry, so a restored session gives the repeated part to the model again. A compaction writes a checkpoint that a restore reads; a repetition stop writes no such record.

## Requirements

1. A restore of a session that had a repetition stop gives the model the same render that the live session gave it after the stop.
2. The recorded transcript keeps full fidelity: the full entry stays in the record.

## Acceptance

- A test: a session stops a call for repetition, the host restores the session, and the next call of the restored session does not receive the repeated part. The record still holds the full entry.

## Related

- ^1hcwaqy: the repetition stop and the render trim (`RepeatedPartRemoval` in `RoutedSessionActorRepetitionWatch.swift`).
- ^tpsc0nf: the render and the full-fidelity record.