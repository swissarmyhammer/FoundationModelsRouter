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
- actor: claude-code
  id: 01m7rmepx8hm9349pxkydhjwz5
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 8 findings (8 confirmed, 5 refuted). Additional checks: 7 findings. Engine: FIFOGenerationLock.swift:62, LockWaitStallWatchTests.swift:213, :298, :313, PoolEntrySharingTests.swift:239, SessionLanguageModelPassTests.swift:52, :108, SharedModelLockContentionTests.swift:71. Additional: IdenticalToolCallLimitTests.swift:85, RunSettledInsideAnAnswerTests.swift:18 (.timeLimit stays), ToolBodyHoldsNoLockTests.swift:351, :353 (no end on the answer tasks), SummarizerSubmissionTests.swift:213, PooledResidencyTests.swift:432, :435 (no failure event, not in the three documented waits). The race fix is correct: no lost wake, the double wake does not break the reader, no busy loop. The new test fails with the old form (a stand-alone run gave 0 wakes).
    - next: implement the open items of the Review Findings (2026-11-18 18:42) section
  timestamp: 2026-11-19T00:49:08.008602+00:00
- actor: claude-code
  id: 01m7rmfg3wvaky2jk4ac5qfhcp
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — LiveModelLoader.swift (readTrackingChanges: the race fix), TranscriptChangeWakeTests.swift (new), BoundedWait.swift (deleted), about 100 waits in 15 test files
    - test: green — one full swift test run, 2971 tests in 344 suites (+49, +19), 0 failures
    - commit: 7d34bb21
    - review: findings — 15 items, all in tests: reuse (FIFOGenerationLock.swift:62, LockWaitStallWatchTests.swift:213/298/313, PoolEntrySharingTests.swift:239, SessionLanguageModelPassTests.swift:52/108, SharedModelLockContentionTests.swift:71); `.timeLimit` left (IdenticalToolCallLimitTests.swift:85, RunSettledInsideAnAnswerTests.swift:18); waits that do not end on an event that exists (ToolBodyHoldsNoLockTests.swift:351/353); waits with no event and no comment (SummarizerSubmissionTests.swift:213, PooledResidencyTests.swift:432/435). The race fix itself was checked and is correct.
  timestamp: 2026-11-19T00:49:33.820699+00:00
- actor: claude-code
  id: 01m7rmxmrryy70mm2xp9709txj
  text: 'Review fixes (all 15 items). Reuse: new ChangeSignal.wait(untilAtLeast:of:endingOnEndOf:sourceLocation:) in Helpers/ChangeSignalWait.swift; FIFOGenerationLock.waitForWaiters(_:endingOnEndOf:), ObservedPassLog.waitForPasses(_:endingOnEndOf:), MailQueueFixtures waitForPrompts(_:endingOnEndOf:), CancelForegroundTests.awaitOpenQuestions and RespondRunPlaneDrainTests use it. New PassObservingFixture.waitUntilTheFirstPassEntered(endingOnEndOf:) replaces the 6 inline copies (SessionLanguageModelPassTests x2, SharedModelLockContentionTests, NestedGenerationReentryTests, SummarizerSubmissionTests, PoolEntrySharingTests). LockWaitStallWatchTests: private helpers waitUntilTheToolBodyStarts(log:endingOnEndOf:) and waitForAStall(in:endingOnEndOf:). PoolEntrySharingTests: private startCall(inside:_:) starts an embed call and waits for its permit. Time limits: .timeLimit removed from IdenticalToolCallLimitTests, RunSettledInsideAnAnswerTests, and also NoOpToolCallWithNothingPendingTests (found by the search); no other .timeLimit or deadline in Tests/ or IntegrationTests/ (tracked files). The IdenticalToolCallLimit and NoOp suites wait only on the end of the answer stream. RunSettledInsideAnAnswerTests has no failure event before the settled event (the tool body holds the answer), so it has the take-stacks comment. New RecordedWaitResult.endOfEither(_:_:) (two recordingEnd records on one signal) gives the end of either task. ToolBodyHoldsNoLockTests release loop: the waiter wait ends on endOfEither of the two answers; the next-pass wait ends on the answer that owns the next pass. Why not endOfEither for the pass wait: after a release, the released pass can be the last pass of its answer, so that answer can end before the next pass records, and the test could fail in a run the program passes. The owner of the next pass cannot end before that pass starts, and if the other answer fails, the next pass still starts. SummarizerSubmissionTests: the abandoned waiter leaves the lock in unlock() of the flash pass, before the flash answer ends, so the wait is now one read. PooledResidencyTests: the two calls are Tasks, and both waits end on endOfEither; the two other waits in the file without an event (waitUntilNothingIsResident, entrySignal.wait) got the take-stacks comment. New task ^8kw2ya3 records the Task.sleep calls that remain in MeteredToolLoopLanguageModel and SessionIndexRecordingTests (not deadlines).'
  timestamp: 2026-11-19T00:57:17.336321+00:00
- actor: claude-code
  id: 01m7rmxszkg8yqz6pvz8e7qkhg
  text: |-
    ### implement — changed
    - evidence: 19 test files changed (Helpers/ChangeSignalWait.swift, Helpers/FIFOGenerationLock.swift, Helpers/PassObservingModel.swift, Helpers/PassObservingFixture.swift, Helpers/RecordedWaitResult.swift, Helpers/MailQueueFixtures.swift, LockWaitStallWatchTests, PoolEntrySharingTests, SessionLanguageModelPassTests, SharedModelLockContentionTests, NestedGenerationReentryTests, SummarizerSubmissionTests, IdenticalToolCallLimitTests, NoOpToolCallWithNothingPendingTests, RunSettledInsideAnAnswerTests, ToolBodyHoldsNoLockTests, PooledResidencyTests, CancelForegroundTests, RespondRunPlaneDrainTests). No production change. Changed suites (regex filter FoundationModelsRouterTests.(13 suites)/): 86 tests in 13 suites passed. Full swift test once: 2971 tests in 344 suites passed, plus 49 in 26 and 19 in 3; only the known mlx Cmlx bundle warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-run-2.txt. All 15 findings are [x].
    - next: review
  timestamp: 2026-11-19T00:57:22.675353+00:00
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

## Review Findings (2026-11-18 18:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 19 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift, so its declarations are unread

- [x] `Tests/FoundationModelsRouterTests/Helpers/FIFOGenerationLock.swift:62` `reuse/reuse` — The new overload waitForWaiters(_:endingOnEndOf:) copies the threshold-and-task wait pattern of waitForPasses(_:endingOnEndOf:) in PassObservingModel.swift. Both call changes.wait(until: count >= threshold, endingOnEndOf: task). The only differences are the counter and the owner type. A parallel copy means two places to fix the same wait rule. Add one ChangeSignal method, for example wait(untilAtLeast:endingOnEndOf:of:sourceLocation:), that builds the predicate from the count. Rewrite waitForWaiters(_:endingOnEndOf:) and waitForPasses(_:endingOnEndOf:) as one-line calls to it, and make the existing untilAtLeast methods use the same helper.
- [x] `Tests/FoundationModelsRouterTests/LockWaitStallWatchTests.swift:213` `reuse/reuse` — The wait for the tool body to start, ended by the answer, is written inline here and again at line 298 of the same file. The two copies can drift apart. Add a private static helper in LockWaitStallWatchTests, for example waitUntilTheToolBodyStarts(log:endingOnEndOf:), and call it from both tests.
- [x] `Tests/FoundationModelsRouterTests/LockWaitStallWatchTests.swift:298` `reuse/reuse` — The second inline copy of the wait for the tool body to start repeats the wait at lines 213-214 of the same file. Replace with the shared private helper used by the other test in this file.
- [x] `Tests/FoundationModelsRouterTests/LockWaitStallWatchTests.swift:313` `reuse/reuse` — The second copy of the wait for a stall report repeats the wait at line 240 of the same file. Replace with the shared private helper used by the other test in this file.
- [x] `Tests/FoundationModelsRouterTests/PoolEntrySharingTests.swift:239` `reuse/reuse` — The wait for the embed gate to take a permit, ended by the router call, repeats the wait for the direct call at line 237 of the same test with the same shape. Use a single helper that takes the task to end on, and call it for both embed calls, or keep the two calls adjacent with one shared wait.
- [x] `Tests/FoundationModelsRouterTests/SessionLanguageModelPassTests.swift:52` `reuse/reuse` — The inline wait for the first pass to enter the model repeats the same wait used in other suites, including a second copy in this same file at line 108. Replace both copies in this file with the shared helper for the first pass entering the model.
- [x] `Tests/FoundationModelsRouterTests/SessionLanguageModelPassTests.swift:108` `reuse/reuse` — The second inline copy of the first-pass-entered wait in this file repeats the wait already written at line 52. Replace with the shared helper for the first pass entering the model.
- [x] `Tests/FoundationModelsRouterTests/SharedModelLockContentionTests.swift:71` `reuse/reuse` — The inline wait for the first pass to enter the model repeats the same wait used in other suites. Replace with the shared helper for the first pass entering the model.

### Additional checks (requested by the caller of the review)

Results that pass:

- The race fix in `MLXFoundationModelsSessionBackend.readTrackingChanges(of:onChange:)` is correct. A write before the install sends one wake. A write after the install sends one wake. A read with no write sends no wake, so no busy loop occurs. A stand-alone run of the old form (Swift 6.4.2) gave 0 wakes for a write in the window, so `aWriteBeforeTheInstallWakes` fails without the fix. A double wake can occur: an observation of an earlier read that a write in the window did not fire stays installed, and fires together with the next observation. The stream keeps only the newest wake, and `RepetitionDetector.readCompleteLines` reads only new lines, so a second read of the same entries does not break the reader.
- The three documented waits have no separate failure event: `Helpers/OverlapGatedMetadataSource.swift` (the held read), `ToolBodyHoldsNoLockTests.swift:383` (the parent answer), `ToolResultCompactionTests.swift:149` (the drain). Each one waits on a deadlock of the code under test.

Findings:

- [x] `Tests/FoundationModelsRouterTests/IdenticalToolCallLimitTests.swift:85` — A wall-clock limit `.timeLimit(.minutes(1))` stays in the tests. The task says "no longer limits", and the user rule says no `.timeLimit` traits on tests. This commit did not change this line. Remove the trait, and make each wait of the suite end on its event.
- [x] `Tests/FoundationModelsRouterTests/RunSettledInsideAnAnswerTests.swift:18` — A wall-clock limit `.timeLimit(.minutes(1))` stays on the suite. This commit did not change this line. Remove the trait, and make each wait of the suite end on its event.
- [x] `Tests/FoundationModelsRouterTests/ToolBodyHoldsNoLockTests.swift:351` — `lock.waitForWaiters(1)` in the release loop does not end on a failure event, but a failure event exists: the end of `firstAnswerTask` or of `secondAnswerTask`. If one answer fails, the wait hangs. Make the wait end when one of the two answers ends.
- [x] `Tests/FoundationModelsRouterTests/ToolBodyHoldsNoLockTests.swift:353` — `passes.waitForPasses(released + 1)` in the same loop does not end on a failure event, but the end of `firstAnswerTask` or of `secondAnswerTask` is one. Make the wait end when one of the two answers ends.
- [x] `Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift:213` — `lock.changes.wait(until: { await lock.waitingCount == 0 })` has no failure event and no comment. The statement "three waits have no such event" is thus not complete. A regression that keeps the abandoned waiter in the lock hangs the test here. Make the wait end on an event, or read the state one time if the removal comes before the end of the answer, or write the comment that tells the reader to take stacks.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:432` — `observer.changes.wait(until: { await observer.active == 1 })` has no failure event and no comment. The two calls are `async let` children, so no task end is available, but a `Task` for each call gives one. Make the wait end when a call ends, or write the comment that tells the reader to take stacks.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:435` — `lock.waitForWaiters(1)` has no failure event. Its comment gives the `async let` cause, but it does not tell the reader to take stacks, and it is not one of the three documented waits. Make the wait end when a call ends (use a `Task` for each call), or write the same comment as the three documented waits.