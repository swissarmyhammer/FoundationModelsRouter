---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4v70hs2jn992xzadzmv6s2x
  text: 'Started: a sub agent implements part C. User rules: compact runs in the signal order; cancelAll during a compaction runs after it and does not touch the pause counter; close cancels a running compaction (compactionFailed, cancelled).'
  timestamp: 2026-10-13T18:04:50.338633+00:00
- actor: claude-code
  id: 01m4vad0ndeqfmgrdechj18h7x
  text: Done in commit dce9ba94. The build is clean. The full suite passed 3 of 3 runs (1648 tests in 204 suites, 2 known issues). There is a possible timing flake in ToolCallRepetitionStopTests.repeatedSnippetStopsBeforeTheToolRuns (1 failure in 9 runs of the sub agent). The report and its 9 differences went to the reviewer.
  timestamp: 2026-10-13T19:04:04.525690+00:00
position_column: done
position_ordinal: ffffffd780
title: 'C1-C4: Compaction as a signal with one path'
---
C1: `compact(prompt:budget:)` returns a `SignalID` at once. It pauses the mail queue, sends `compactionStarted`, then `compaction` or `compactionFailed` with `Origin.signal(id)`, then resumes. Remove `compactionRequests` and `CompactionRequestMailbox`.
C2: Add `CompactionReason.requested`.
C3: Merge `performAutoCompaction` and `compactOwnModel` into one handler. Each automatic trigger starts it with its reason and a new `SignalID`. Flash tier first, own model as the fallback.
C4: Change the doc of `compact`, the retry pattern and the tests to the "wait for the terminal event" helper.
Commit with build and tests green, then report. #mail