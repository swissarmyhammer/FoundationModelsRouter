---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Count tool calls and snapshots as progress in the stall watchdog
---
## Problem

The stall watchdog (`Session/GenerationStall.swift`) counts only text fragments of the outer stream. A tool-using turn makes tool calls and reasoning with no new response text. Evidence: django__django-13964, 2026-09-21: "generation has produced no fragment in 2103.3s (0 so far)" every 30 seconds at error level, while the model made 41 rounds of tool calls.

## Cause

`SnapshotDeltaIterator` (`Resolution/LiveModelLoader.swift:315`) gives a fragment only when `snapshot.content` changes. Tool calls, tool results and reasoning do not change `content`. Thus `noteGenerationFragment()` is not called.

## Do this

1. Note progress on each append: a new transcript entry in a snapshot, and each tool call open and close in `ToolRun`.
2. Measure the stall against the newest append, not against the first fragment of the turn.
3. Change the report text so it names the last append kind and its age, for example "no progress for 45s since the last tool result".

## Acceptance

- A test with a fake backend that makes tool calls and no text for longer than the interval gets no stall report.
- A test where the backend stops after a tool result gets a stall report that names the tool result.

Requested by foundationmodelsacpagent-08. Depends on no other task. #compaction