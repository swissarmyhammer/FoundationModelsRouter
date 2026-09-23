---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37d6nqy2f91t2gx59zcbxy0
  text: |-
    ### implement — changed
    Design choices (recorded here, made without a question):
    - New public enum `GenerationProgressKind` (callStart, fragment, reasoning, toolCall, toolResult, transcriptEntry) in `Session/GenerationStall.swift`. `GenerationStall` has a new field `lastProgress`. The report text is now "generation has made no progress for Ns since the last tool result (K fragments so far, Ms in flight)".
    - `noteGenerationFragment()` is replaced by `noteGenerationProgress(_:)`. Each append restarts the interval. Only a `.fragment` append adds to the fragment count.
    - Snapshot path: `ResponseFragment` has a new field `progress` (default `.fragment`). `SnapshotDeltaIterator` in `Resolution/LiveModelLoader.swift` now also reads `transcriptEntries`. A snapshot that adds entries and no text gives a fragment with empty text and the kind of the newest entry. Empty text makes no `.textDelta` and no String chunk, so callers see no change.
    - Tool path: `RoutedSessionActor.deliver(invocation:)` (the session end of the `ToolRun` open and close records) notes `.toolCall` for an open record and `.toolResult` for a close record. This also covers a `respond` turn, which has no fragments.
    - Known limit: a close record of a background run that settles while a different model call is in flight also counts as progress for that call. The record does not name the model call.
    - Tests in `GenerationStallDiagnosticTests`: tool calls with no text for longer than the interval give no stall; a stream that stops after a tool result gives a stall that names the tool result; a `respond` turn measures from the last invocation record; the report text. The existing log test now looks for "generation has made no progress".
    - Evidence: `swift test` 1316 + 1 + 19 tests pass (2 known issues are old). `swift build --build-tests --package-path IntegrationTests` completes.
  timestamp: 2026-09-23T15:12:31.998513+00:00
position_column: doing
position_ordinal: '80'
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