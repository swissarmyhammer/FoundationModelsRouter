---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Make the model-lock wait tests and the full-suite hang deterministic
---
## Problem

While ^gw486td was in work, three full `swift test` runs on one build gave three different results. Other `swift test` processes ran on the machine at the same time (load average about 19).

- Run 1: 15 tests failed with "the wait at <file>:<line> did not end inside its limit of 60 s". Files: `ToolBodyHoldsNoLockTests.swift` (8), `LockWaitStallWatchTests.swift` (3), `ChildStarvationRegressionTests.swift` (1), `NestedGenerationReentryTests.swift` (1), `SubmissionQueueSpikeTests.swift` (1), `ToolResultCompactionTests.swift` (1). Examples: ToolBodyHoldsNoLockTests.swift:511, :431, :383, :539, :308, :352, :461; LockWaitStallWatchTests.swift:177; ToolResultCompactionTests.swift:149; ChildStarvationRegressionTests.swift:72; SubmissionQueueSpikeTests.swift:207.
- Run 2: the test process stopped. It wrote no output for more than 30 minutes, at 0% CPU, and was killed. The output is buffered, so the stuck test is not known. The last text in the log was the start of the test name "stop, act, stop, act: each of the four reasoning stops recovers". `sample` shows only idle threads (suspended async work).
- Run 3, with no code change after run 2: 3037 tests passed (2969 Swift Testing tests in 343 suites, plus 49 and 19).

## Work

Find why each of these waits depends on the load of the machine, and why run 2 stopped. Make each test deterministic: no longer limits, no sleeps, no retries. Each wait must end, so a broken path fails and does not hang.