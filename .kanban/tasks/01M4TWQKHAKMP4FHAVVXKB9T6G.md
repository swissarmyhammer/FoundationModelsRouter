---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: 'C1-C4: Compaction as a signal with one path'
---
C1: `compact(prompt:budget:)` returns a `SignalID` at once. It pauses the mail queue, sends `compactionStarted`, then `compaction` or `compactionFailed` with `Origin.signal(id)`, then resumes. Remove `compactionRequests` and `CompactionRequestMailbox`.
C2: Add `CompactionReason.requested`.
C3: Merge `performAutoCompaction` and `compactOwnModel` into one handler. Each automatic trigger starts it with its reason and a new `SignalID`. Flash tier first, own model as the fallback.
C4: Change the doc of `compact`, the retry pattern and the tests to the "wait for the terminal event" helper.
Commit with build and tests green, then report. #mail