---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: A restored session must restore the context counter from the newest generation call, not from the sum on the response stamp
---
## Problem

^tpsc0nf makes the context counter of a live session the size of the render: the fed and generated tokens of the newest generation call. It is not the sum of the calls of a tool loop.

A restored session does not follow this rule. `TranscriptTree.restoredUsageState(in:)` (Recording/TranscriptReconstruction.swift) reads `newestStampedUsage(in:)`: the `tokensIn`/`tokensOut` stamp on the newest `.response` event. That stamp is the SUM of the generation calls of the attempt (it is the cost of the attempt, and it stays the sum). So after a restore, `contextFill` reports the sum again, for example 1.877 in the run of ^tpsc0nf.

The tree gives `restoredUsageState` only entry events (`effectiveEntryEvents(forSession:)` reads `entryKindEvents`). The `.generationCall` events, which carry the usage of each call, are not in that list.

## Expected

- A restored session reads its counter from the newest `.generationCall` event after the newest compaction checkpoint: `tokensIn + tokensOut` of that call.
- With no such event after the checkpoint, the counter is the `tokensAfter` of the checkpoint.
- A journal with no `.generationCall` event (an old journal) keeps the present rule.

## Acceptance

- A test: a journal with a tool loop of three calls restores the counter of the last call, not the sum on the `.response` stamp.
- A test: a journal with a compaction checkpoint and no call after it restores `tokensAfter`.
- A test: an old journal with no `.generationCall` event restores the `.response` stamp as before.

## Source

Found during the implement step of ^tpsc0nf. That card does not name the restore path, so it is a separate task.