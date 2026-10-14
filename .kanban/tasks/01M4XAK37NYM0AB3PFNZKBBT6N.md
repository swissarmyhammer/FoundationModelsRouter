---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffe180
title: An injectable clock for the stall watch in GenerationStall
---
The stall report timer is owned by Router (GenerationStall.swift, Task.sleep(for: interval), and ContinuousClock.now for the stall measures). Tests set unreachableReportInterval (600 s) so that the timer does not fire during a test step. That is a time bound, so the test result depends on timing.

Do:
- Add an injectable clock for the stall watch. The real clock is the default, and the public API stays the same.
- In QueuedPassStallWatchTests and GenerationStallDiagnosticTests, use a test clock that the test advances in a fixed order. Remove unreachableReportInterval as a time bound.
- No sleeps, polls, time limits or retries in the tests.

Run the full suite one time. Push when green (user order). Tell the reviewer the pushed head, because ACPAgent builds against Router main. The Extras timers stay with task 01M4X8KFFMSSAXSMN8QFVJGN5K. #test