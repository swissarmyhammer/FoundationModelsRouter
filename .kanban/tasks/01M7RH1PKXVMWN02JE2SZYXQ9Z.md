---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rkezrj0q8b9c6vz4twj1en
  text: 'Research. (1) The 60 s message comes from Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift: a wall-clock race (Task.sleep 60 s) around about 100 waits in 15 files. Under a full parallel run at load 19, one test''s chain of hops can take more than 60 s, so the limit fails a correct test: a made-up failure. (2) The hang was reproduced once in a single run of a probe test (keyReorderedRepeatIsNoProgress scripts) at load about 17. swift-inspect dump-concurrency: the StagedReasoningModel call waits in AwaitedEvent.wait (hold untilStopped); the repetition watch task waits for its next transcript value; the pass-watch relay waits in observeTranscript for the next change; all actors idle. So the watch never read the last reasoning lines, and never stopped the call. Cause: MLXFoundationModelsSessionBackend.observeTranscript uses withObservationTracking(options: .didSet). That function records the access in apply, and installs the tracking only after apply returns. An SDK write of the transcript between the read and the install has no observer, so no wake comes. When that write is the last one of the pass (the model then holds), the relay waits for good. This is a router defect, not a test-model defect. The fix: after the install, read again, and wake at once when the value changed.'
  timestamp: 2026-11-19T00:31:48.498554+00:00
- actor: claude-code
  id: 01m7rm22a5ejjrdkzp42bm5ajj
  text: |-
    ### implement — changed
    - evidence: Hang cause (router): MLXFoundationModelsSessionBackend.observeTranscript used withObservationTracking(options: .didSet), which installs its observation only after the read. An SDK transcript write in that window sent no wake; when it was the last write of a pass, the repetition watch never read the last reasoning lines, never stopped the call, and the untilStopped hold waited for good. Reproduced once in a single probe run (stacks: model in AwaitedEvent.wait, watch and pass-watch relay waiting, actors idle). Fix: new MLXFoundationModelsSessionBackend.readTrackingChanges(of:onChange:) reads again after the install and wakes at once when the value changed. Fixed-order test TranscriptChangeWakeTests (3 tests; the write-in-window test failed before the fix, passes after). Wait cause: BoundedWait (60 s wall-clock race) failed correct tests under full-suite load. BoundedWait.swift is deleted; all about 100 waits in 15 files now wait for events; new rule-T1 overloads ObservedPassLog.waitForPasses(_:endingOnEndOf:) and FIFOGenerationLock.waitForWaiters(_:endingOnEndOf:); lock, pass, delivery and stall-watch waits end on the end of their answer, or on endingWhenWorkEnds; the tool-body stall check reads the watch once after the pass ends (state check). Changed suites: 97 tests in 15 suites passed. Full swift test once: 2971 tests in 344 suites passed, plus 49 and 19; only the known mlx Cmlx bundle warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-run.txt
    - next: review
  timestamp: 2026-11-19T00:42:13.701139+00:00
position_column: doing
position_ordinal: '80'
title: Make the model-lock wait tests and the full-suite hang deterministic
---
## Problem

While ^gw486td was in work, three full `swift test` runs on one build gave three different results. Other `swift test` processes ran on the machine at the same time (load average about 19).

- Run 1: 15 tests failed with "the wait at <file>:<line> did not end inside its limit of 60 s". Files: `ToolBodyHoldsNoLockTests.swift` (8), `LockWaitStallWatchTests.swift` (3), `ChildStarvationRegressionTests.swift` (1), `NestedGenerationReentryTests.swift` (1), `SubmissionQueueSpikeTests.swift` (1), `ToolResultCompactionTests.swift` (1). Examples: ToolBodyHoldsNoLockTests.swift:511, :431, :383, :539, :308, :352, :461; LockWaitStallWatchTests.swift:177; ToolResultCompactionTests.swift:149; ChildStarvationRegressionTests.swift:72; SubmissionQueueSpikeTests.swift:207.
- Run 2: the test process stopped. It wrote no output for more than 30 minutes, at 0% CPU, and was killed. The output is buffered, so the stuck test is not known. The last text in the log was the start of the test name "stop, act, stop, act: each of the four reasoning stops recovers". `sample` shows only idle threads (suspended async work).
- Run 3, with no code change after run 2: 3037 tests passed (2969 Swift Testing tests in 343 suites, plus 49 and 19).

## Work

Find why each of these waits depends on the load of the machine, and why run 2 stopped. Make each test deterministic: no longer limits, no sleeps, no retries. Each wait must end, so a broken path fails and does not hang.