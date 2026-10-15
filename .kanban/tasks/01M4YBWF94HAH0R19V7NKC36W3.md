---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ycade6nm0n5xnp4tsmavjx
  text: |-
    Research (cause confirmed in the code):

    - close() (Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:354) runs performCancelAll() and then waits for the drain (RoutedSessionActorForking.swift:398).
    - The drain (Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:144-162, runDrain) waits for the sweep, the run bodies, the compaction and the pump. It has no wait for a generation pass.
    - The pump waits for the model call (Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift:883-887, `try await modelCall.value`), and the model call waits for the SDK call `LanguageModelSession.respond`/stream.
    - The framework resumes a cancelled SDK call WITHOUT a wait for its executor (mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift:948-949: "The framework resumes a cancelled `LanguageModelSession.respond` WITHOUT awaiting this executor"). The executor pass runs on a task of the framework (Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:110-114, 129-143).
    - Thus the pass of a stopped answer (SessionLanguageModel.Executor.respond, with its pass watch that keeps the LanguageModelSession and the request with its tools) continues after the pump ended and after close() returned. While that pass runs, its references keep the model handles of the profile (RoutedModel.residencyHolds, Sources/FoundationModelsRouter/LanguageModelProfile.swift:126), and the next resolve sees a full pool.
    - The one point that the session can see is the pass observer: SessionLanguageModel.Executor.respond calls GenerationPassObserver.passStarted() before the pass and passEnded() in a defer (SessionLanguageModel.swift:134-136), after the pass watches ended.

    Plan: GenerationPassObserver counts the open passes and signals each pass end. The drain of close() waits until no pass is open, after the pump ended. cancelAll() does not change. No new deadlock edge: a pass runs no tool body and waits for no close; a close from a tool body or a run body of the same session already waits for the pump or the run body.
  timestamp: 2026-10-14T23:35:19.750765+00:00
- actor: claude-code
  id: 01m4ycprb6wchbvzkk0dnz1dmy
  text: |-
    Implementation landed.

    - Test: SessionDrainTests.closeWaitsForTheGenerationOfTheStoppedModelCall. The hook of the model call starts a detached generation (passStarted, keeps a ModelHandleLease of fixture.model, waits on a gate), and the model call throws CancellationError at its cancel, as the framework does. A task opens the gate only when a close waits on passEnds (waiterChanges). Expects steps == ["generation ended", "closed"], the weak lease nil, openPassCount 0.
    - RED at the old drain (no wait): steps.values -> ["closed"]; lease == nil failed (the lease still held the RoutedLLM with its residencyHolds); openPassCount -> 1. No hang.
    - GREEN after `await generationPassObserver.awaitNoOpenPass()` in runDrain().
    - Why not a pool-count check: after close() returns, the stall watchdog and the pass-report reader tasks of the session are cancelled but not awaited, so a check of the pool footprint after a drop of the session is not deterministic. The weak lease is the deterministic point.
    - Touched suites one time (SessionDrainTests|QueuedPassStallWatchTests|SessionRunPlaneTests|CancelAllSignalTests): 25 tests in 4 suites passed.
    - Full suite one time: "Test run with 1699 tests in 205 suites passed after 6.137 seconds with 1 known issue." (the known issue is the existing withKnownIssue in RealModelHarnessTests), "Test run with 25 tests in 13 suites passed", "Test run with 19 tests in 3 suites passed".
    - swift build --build-tests and IntegrationTests swift build --build-tests: zero warnings (only the mlx "missing creator for mutated node" line).
    - Not pushed: the order for this work says do not push.
  timestamp: 2026-10-14T23:42:04.134380+00:00
- actor: claude-code
  id: 01m4ycq3tphrm1wct4srgjsyxs
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Tests/FoundationModelsRouterTests/SessionDrainTests.swift; full suite 1699 tests in 205 suites passed (1 known issue that existed before); IntegrationTests build clean. One commit on close-wait, not pushed.
    - next: /review
  timestamp: 2026-10-14T23:42:15.894600+00:00
- actor: claude-code
  id: 01m4yczejmjagz2hrngz2yqepj
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: engine 1 finding (1 confirmed, 1 refuted). Hand checks: 2 findings. Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift:172, Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:165, Tests/FoundationModelsRouterTests/SessionDrainTests.swift:314. Hand checks with no finding: no new deadlock in awaitNoOpenPass (each session has its own observer, a fork has a new wrapper, a pass runs no tool body and calls no close, the MLX executor returns only after its generation is quiet); cancelAll() does not wait (only close() calls startDrainIfNeeded); the test has a fixed order with no time and is red with no hang without the fix. The open push item of subtask 4 is the orchestrator step and is not a finding.
    - next: /implement the three open findings of "Review Findings (2026-10-14 18:43)", then /review again.
  timestamp: 2026-10-14T23:46:49.044323+00:00
- actor: claude-code
  id: 01m4ydzvd6n9d73ecn7dada8qq
  text: |-
    Review findings of 2026-10-14 18:43 fixed (all three).

    1. reuse: ChangeSignal.waitUntil(isolation:_:) is the one wait loop (read changeCount, read the state, wait for the next change; false on cancel). GenerationPassObserver.awaitNoOpenPass, and in RoutedSessionActorCompaction.swift both awaitNoOpenSubmission (throws on false) and awaitActiveCompaction (the same loop, same file) now use it. The test helper ChangeSignal.wait(isolation:until:) in Tests/Helpers keeps its own loop: its condition is async throws.
    2. close-releases-profile: new HelperTaskTracker (Sources/FoundationModelsRouter/Concurrency/HelperTaskTracker.swift), RoutedSessionActor.helperTasks. The stall watchdog, the pass-report reader and the repetition watch start through helperTasks.start(_:). A second task awaits the value of each helper task and only then counts the end and signals taskEnds, so the count is zero only after each helper task released its captures (the runtime releases the closure context before it resumes a wait for the value). runDrain() calls helperTasks.awaitNoLiveTask() after awaitNoOpenPass(). The helper tasks end at their cancel and wait for no close: no deadlock.
       Why not await the tasks inside runCancellableModelCall, or weak capture: an await inside the call gives no point a test can observe without a time, and weak capture still holds self during each hop to the actor, so a hop queued at the return of close keeps the profile.
       Other stored Task handles of the actor checked: pumpTask, drainTask, activeCompaction, sweepTask (all awaited by close/drain), inFlightModelCall (awaited by the pump). Tasks with no handle that close does not cancel: `Task { await self.mailDidArrive() }` (mail(_:)), `Task { await wakePump() }` (end of a compaction), the reader tasks of streamEvents/streamResponse (they end when outputHub.close() finishes the subscription; the consumer owns the stream). Not changed.
    3. Test: SessionDrainTests.closeLeavesNoTaskThatKeepsTheProfile. The session is made by makeSessionThatAloneKeepsItsProfile (fixture, router and profile are gone when it returns). A HeldSleepClock holds the stall watchdog after its cancel until the test opens the clock gate; the test opens it only when the drain waits on helperTasks.taskEnds (waiterChanges). After close() returns, the test awaits the answer, drops the session, and expects the weak profile nil and liveTaskCount 0. closeWaitsForTheGenerationOfTheStoppedModelCall also now drops the session and expects the weak profile nil.
       RED (drain without awaitNoLiveTask): `profile == nil` failed (profile alive with its residencyHolds), `helperTasks.liveTaskCount == 0` failed (1). No hang. GREEN after the drain wait.
       Note: one RED run was repeated with no code change, because the first output was cut by a pipe and did not show the issues.
    - swift build --build-tests: Build complete, zero warnings (only the mlx "missing creator for mutated node" line).
    - Touched suites one time: "Test run with 119 tests in 16 suites passed".
    - Full suite one time: "Test run with 1700 tests in 205 suites passed after 5.696 seconds with 1 known issue.", "Test run with 25 tests in 13 suites passed", "Test run with 19 tests in 3 suites passed".
    - IntegrationTests swift build --build-tests: Build complete, zero warnings.
  timestamp: 2026-10-15T00:04:30.758668+00:00
- actor: claude-code
  id: 01m4ye0cgv5frn7f9d7g8wz3vh
  text: |-
    ### implement — changed
    - evidence: 14 files — Sources/FoundationModelsRouter/Concurrency/ChangeSignal.swift, Concurrency/GenerationPassObserver.swift, Concurrency/HelperTaskTracker.swift (new), Session/RoutedSession.swift (doc only), Session/RoutedSessionActor.swift, Session/RoutedSessionActorAnswerExecution.swift, Session/RoutedSessionActorCompaction.swift, Session/RoutedSessionActorDrain.swift, Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorPassReports.swift, Session/RoutedSessionActorRepetitionWatch.swift, Tests/FoundationModelsRouterTests/AnswerCancellationFixtures.swift, Tests/FoundationModelsRouterTests/SessionDrainTests.swift, plus the .kanban files. RED: profile == nil and liveTaskCount == 0 failed without the drain wait. Full suite: 1700 tests in 205 suites passed (1 known issue that existed before); IntegrationTests build clean. One commit on close-wait ("fix(session): close waits for the stall watch and the pass-report reader"), not pushed.
    - next: /review
  timestamp: 2026-10-15T00:04:48.283629+00:00
- actor: claude-code
  id: 01m4yegh078h52nc617bz33kv2
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (982d2d49). Engine: 0 findings, 1 refuted. The 3 items of the 18:43 review are fixed. Hand checks: 2 findings — Sources/FoundationModelsRouter/Concurrency/ChangeSignal.swift:123, Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:176. No deadlock found (each helper task ends at its cancel; AsyncStream reads end at cancel). The repo has no ARCHITECTURE.md, so no finding for it. The test closeLeavesNoTaskThatKeepsTheProfile has a fixed order, no time, and is red without the wait.
    - next: implementer fixes the 2 open items of the 2026-10-14 19:05 section; the task stays in review.
  timestamp: 2026-10-15T00:13:37.159039+00:00
- actor: claude-code
  id: 01m4yf25mgymwqzj4zndzzv45f
  text: |-
    Picked up the 2 open items of "Review Findings (2026-10-14 19:05)". Research:

    1. reuse: ChangeSignal.waitUntil takes a synchronous condition. awaitIdle() reads its state with `await isIdle()`. Plan: one waitUntil with an async condition (`() async -> Bool`), and move waitForTheRealCallsOfTheRound(ofNoOpCallOf:) and awaitIdle() onto it. Cancel behavior stays: the no-op wait returns at a cancel; awaitIdle returns false at a cancel or a close (checked at the start of each cycle, after each wait, and after the check).
    2. close-releases-profile: three tasks keep the session after close() returns.
       - SignalExecutor.run makes a Task for each signal (`{ [self] in await runSignalWork(...) }` keeps the session). The drain waits only for activeCompaction. The tail of the signal task (endRequestedCompaction, endPending, the idle actions) runs later. Plan: the executor starts its tasks through a HelperTaskTracker of its own, and the drain waits for it after the pass wait. No deadlock: no signal work calls close(); cancelAll work, cancel, replace and the compaction wait for no close. A close from a summarizer tool already waits for the compaction task (cancelActiveCompaction), so no new edge.
       - The idle action of performCompaction starts `Task { await wakePump() }`. Plan: start it through helperTasks (the drain waits for it after the signal wait), and wakePump() starts no pump when isClosed is set.
       - mail(_:) starts `Task { await self.mailDidArrive() }` after the put. A put that comes before the close of the queue can start this task after the drain looked at helperTasks (the thread can stop between the put and the start). Plan: a reservation in HelperTaskTracker, taken before the put, so the count is up before the queue closes; the reservation starts the task after the put, or ends at a refusal.
       Test plan (fixed order, no time): (a) signal B holds, then a requested compaction A, then signal C holds; B opens, A ends and its wake waits for the end of C; close() while C holds; C opens only when the drain waits on the executor tasks. After close, profile weak ref nil and no pump runs. (b) in the isolation of the session: send a mail, read helperTasks.liveTaskCount (1: the arrival task counts and cannot end while the test holds the actor), then close. After close, count 0, no pump, profile nil. (c) wakePump() after close starts no pump.
       A red at HEAD for the mail hop alone cannot have a fixed order: the hop runs at the first suspension of close. So the red for (b) is the count assertion (the arrival task is not tracked).
  timestamp: 2026-10-15T00:23:15.344456+00:00
- actor: claude-code
  id: 01m4yfg9ze2sgyf2cps49cv6cp
  text: |-
    Review findings of 2026-10-14 19:05 fixed (both).

    1. reuse: ChangeSignal.waitUntil(isolation:_:) now takes an async condition (`() async -> Bool`). It is the one wait loop over a change signal in the module. Moved onto it: waitForTheRealCallsOfTheRound(ofNoOpCallOf:) (condition `noOpToolCallStop != nil || noOpToolCallRound.isComplete`, the stop check and mayStopForNoOpToolCall come after the wait; a cancel returns as before) and awaitIdle() (the condition gives true at a cancel or a close with foundIdle false, so the result is false as before; a found idle gives `!isClosed` as before). The synchronous callers (awaitNoOpenPass, awaitNoOpenSubmission, awaitActiveCompaction, awaitNoLiveTask) compile unchanged.
    2. close-releases-profile:
       - SignalExecutor starts each signal task through a HelperTaskTracker of its own (`tasks`), with `taskEnds` and `awaitNoTask()`. runDrain() waits `signals.awaitNoTask()` after awaitNoOpenPass() and before helperTasks.awaitNoLiveTask().
       - The idle action of performCompaction starts its wake through `helperTasks.start { await self.wakePump() }`.
       - mail(_:) takes `helperTasks.reserve()` before the put; a refusal cancels the reservation; after the put the reservation starts `mailDidArrive()`. HelperTaskTracker.Reservation is ~Copyable with consuming start/cancel; start(_:) is now reserve().start(_:).
       - wakePump() returns at once when isClosed is set: no pump starts after close began.
       - Docs: RoutedSession.close(), RoutedSessionActor.close(), runDrain(), helperTasks, HelperTaskTracker, SignalExecutor.
       Deadlock check: no signal work calls close(); performCancelAll, cancel, replace and the compaction wait for no drain; close closed the executor, so a waiting signal runs only its skipped closure. The wake helpers end by themselves.
    3. Tests (SessionDrainTests), fixed order, no time:
       - closeWaitsForTheSignalTasksAndTheWakeAfterACompaction: held signal, then compact(), then a second held signal; the first opens, the compaction ends and its wake waits for the end of the second signal; close() runs; the second gate opens only when the drain waits on signals.taskEnds (waiterChanges). Expects no pump runs after close and the weak profile nil after the drop. (The finding text said "a requested compaction holds at a gate": the empty-session compaction does not call a model, so the held signal behind it holds the tail of the compaction in place of it.)
       - closeWaitsForTheWakeOfAMail: in the isolation of the session, send a mail, read helperTasks.liveTaskCount, close. Expects 1, then 0 after close, no pump, weak profile nil.
       - wakeAfterCloseStartsNoPump: after close, wakePump() and isPumpRunning in one isolated call. Expects false.
       RED (seam SignalExecutor.taskEnds present; drain with no signal wait, untracked hops, no isClosed guard): `profile == nil` failed (SessionDrainTests.swift:444), `liveTasksAfterTheMail == 1` failed (:467), `wakePumpAndReadIt(on:) == false` failed (:486). "Test run with 3 tests in 1 suite failed after 0.064 seconds with 3 issues." No hang. GREEN: "Test run with 3 tests in 1 suite passed after 0.018 seconds."
       A red for the mail hop by profile alone cannot have a fixed order at HEAD (the hop runs at the first suspension of close), so its red is the count assertion.
    - swift build --build-tests: Build complete, zero warnings (only the mlx "missing creator for mutated node" line).
    - Touched suites one time (SessionDrainTests|NoOpToolCallStopTests|SessionIdleWaitTests|CompactionSignalTests|MailSignalTests|CancelAllSignalTests|RoutedSessionCompactTests|AutoCompactionTests): "Test run with 94 tests in 8 suites passed after 0.161 seconds."
    - Full suite one time: "Test run with 1703 tests in 205 suites passed after 4.998 seconds with 1 known issue.", "Test run with 25 tests in 13 suites passed after 0.009 seconds.", "Test run with 19 tests in 3 suites passed after 0.007 seconds."
    - IntegrationTests swift build --build-tests: Build complete, zero warnings.
  timestamp: 2026-10-15T00:30:58.542658+00:00
- actor: claude-code
  id: 01m4yfgd52g65293ypfw93d907
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsRouter/Concurrency/ChangeSignal.swift, Concurrency/HelperTaskTracker.swift, Session/NoOpToolCallStop.swift, Session/RoutedSession.swift (doc), Session/RoutedSessionActor.swift (doc), Session/RoutedSessionActorCompaction.swift, Session/RoutedSessionActorDrain.swift, Session/RoutedSessionActorForking.swift (doc), Session/RoutedSessionActorIdle.swift, Session/RoutedSessionActorPump.swift, Session/RoutedSessionActorQueueing.swift, Session/SignalExecutor.swift, Tests/FoundationModelsRouterTests/SessionDrainTests.swift, plus .kanban. RED: 3 assertions failed, no hang. Full suite: 1703 tests in 205 suites passed (1 known issue that existed before), 25 in 13, 19 in 3; IntegrationTests build clean. One commit on close-wait, not pushed.
    - next: /review
  timestamp: 2026-10-15T00:31:01.794226+00:00
- actor: claude-code
  id: 01m4yfxjds6s6fp96agm71c70m
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (b080e537). 2 findings (2 confirmed, 0 refuted): Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:47, Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:52 (duplication/duplication, one cause: the refusal cleanup of mail(_:) is in two places).
    - prior items: the 2 findings of 2026-10-14 19:05 are fixed. The drain waits for signals.awaitNoTask() before helperTasks.awaitNoLiveTask(). The wake after a compaction and the wake after a mail are helper tasks. wakePump() returns when isClosed is true. waitUntil takes an async condition, and the no-op round wait and awaitIdle() use it.
    - hand checks, no new finding: (1) Each Task in Session and Concurrency: the drain waits for it, or it ends before close returns, or it keeps no session (sweepTask, drainTask, pumpTask, the activeCompaction task, the modelCall task, the helper tasks, the signal tasks; the HelperTaskTracker end-watcher keeps only the tracker). (2) A mail put before the queue closes is in the list that close() gets from outbox.queue.close(), and settleCancelledMail gives it its one terminal. A mail put after that is refused. The queue Mutex orders the two, so no mail is lost. (3) No deadlock: a signal work does not call close() or wait for the drain. The automatic compaction signal runs `skipped` (CancellationError) after signals.close(). performCancelAll() as a signal does not wait for the drain. close() from a tool body or from a run body was a deadlock before this commit, and this commit does not change it. (4) Each exit of mail(_:) after reserve() runs cancel() or start(). No code after line 55 throws, so no reservation leaks. (5) The 3 new tests have a fixed order and no time. Each test is red without its part of the fix: profile == nil, liveTasksAfterTheMail == 1, isPumpRunning == false.
    - not counted: subtask 4 ("Push when green"). The orchestrator does this step.
    - next: implement the 2 findings, then commit and review again.
  timestamp: 2026-10-15T00:38:13.177426+00:00
- actor: claude-code
  id: 01m4yg3yy7danprgd9xczpx8w0
  text: |-
    Review findings of 2026-10-14 19:31 fixed (both, one cause).

    - withdrawRefusedMail now does all of the refusal cleanup: it consumes the reservation (`arrival: consuming HelperTaskTracker.Reservation`, then `arrival.cancel()`), unsubscribes, ends the pending record when this call made it, and returns the refusal error. Each refusal branch of mail(_:) is now one `throw withdrawRefusedMail(...)`: the catch branch gives `error`, the duplicate-id branch gives `MailRefusal.duplicateID(mail.id)`.
    - Why a private method and not a local func: Reservation is ~Copyable and its cancel() is consuming, so a local closure or func that captures `arrival` cannot consume it. A consuming parameter can.
    - No other copy of this cause in the file. Behavior and order of the cleanup do not change (cancel, unsubscribe, endPending).
    - swift build --build-tests: Build complete, zero warnings (only the mlx "missing creator for mutated node" line).
    - Touched suites one time (SessionDrainTests|SessionMailQueueTests|MailSubscriptionTests|MailSignalTests|MailQueueBatchTests|MailPublicSurfaceTests): "Test run with 79 tests in 5 suites passed after 0.116 seconds.", "Test run with 2 tests in 1 suite passed after 0.001 seconds."
    - Full suite one time: "Test run with 1703 tests in 205 suites passed after 4.565 seconds with 1 known issue.", "Test run with 25 tests in 13 suites passed after 0.015 seconds.", "Test run with 19 tests in 3 suites passed after 0.006 seconds."
    - IntegrationTests swift build --build-tests: Build complete, zero warnings.
  timestamp: 2026-10-15T00:41:42.599469+00:00
- actor: claude-code
  id: 01m4yg40tweh69n3jt6mv402hd
  text: |-
    ### implement — changed
    - evidence: 1 source file — Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift, plus .kanban. Full suite: 1703 tests in 205 suites passed (1 known issue that existed before), 25 in 13, 19 in 3; IntegrationTests build clean. One commit on close-wait, not pushed.
    - next: /review
  timestamp: 2026-10-15T00:41:44.540617+00:00
- actor: claude-code
  id: 01m4yg7ngcczyeys45fym917rb
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (0d29b742). 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The 2 findings of the 2026-10-14 19:31 review are fixed: mail(_:) calls withdrawRefusedMail once in each branch and only throws its result. arrival.cancel() and the cleanup are only in withdrawRefusedMail (Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift).
    - next: the card is in done. The orchestrator does the push.
  timestamp: 2026-10-15T00:43:44.012642+00:00
position_column: done
position_ordinal: ffffffe380
title: close() waits until the generation task of each stopped answer ends and releases its model handles
---
Found by Multitool commit 889e0f2 (Multitool main). RoutedSession.close() returns before the generation task of a cancelled answer ends. Thus the session keeps its profile (its model handles) in the model pool after close() returns, and the next resolve sees a full pool. The part F doc says: "when close returns, the session holds no work".

- [x] Confirm the cause in the code.
- [x] close() waits until the generation task of each stopped answer has ended and released its model handles. cancelAll() still does not wait. Only close() waits.
- [x] Fixed-order test: a cancelled answer whose generation is held at a gate. close() does not return before the gate opens and the task ends. After close() returns, no reference of the session holds the profile.
- [x] No public API change. One commit on top of 3f3ba209, apart from the held work-event commits. One full run and the IntegrationTests build. Push when green. (The four work commits are squashed into one commit, and the orchestrator pushed it.)

## Cause

- close() (Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, `close()`) waits for the drain (`startDrainIfNeeded().value`).
- The drain (Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:144-162 at 3f3ba209, `runDrain()`) waited for the sweep, the run bodies, the compaction and the pump, and for no generation pass.
- The pump waits for the model call (Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift:883-887, `try await modelCall.value`), and the model call waits for the SDK call.
- The framework resumes a cancelled SDK call with no wait for its executor (mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift:948-949). The pass runs on a task of the framework (Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:110-114, 129-143). Thus the pass of the stopped answer ran on after close() returned, and its references kept the model handles of the profile (RoutedModel.residencyHolds).

## Fix

- GenerationPassObserver counts the open passes (passStarted / passEnded), signals each pass end (`passEnds`), and gives `awaitNoOpenPass()`.
- runDrain() calls `generationPassObserver.awaitNoOpenPass()` after the pump ended, in each cycle. Only close() runs the drain; cancelAll() does not wait.
- No new deadlock edge: a pass runs no tool body and waits for no close.
- ChangeSignal.waitUntil(isolation:_:) is the one wait loop over a change signal in the module. Its condition is async, so a condition can read the state of another actor. awaitNoOpenPass, awaitNoOpenSubmission, awaitActiveCompaction, HelperTaskTracker.awaitNoLiveTask, the no-op round wait (waitForTheRealCallsOfTheRound(ofNoOpCallOf:)) and awaitIdle() use it.
- HelperTaskTracker (RoutedSessionActor.helperTasks) starts the helper tasks of the session: the stall watchdog, the pass-report reader and the repetition watch of a model call, and the wake of the pump after a mail and after a compaction. A second task waits for the value of each helper task and only then counts its end, so the count is zero only after each helper task released its captures. mail(_:) reserves its wake before the put (HelperTaskTracker.reserve()), so a put that comes before the close of the queue is counted before the drain looks. runDrain() calls `helperTasks.awaitNoLiveTask()` after the pass wait. A helper task ends at its cancel or by itself and waits for no close, so no deadlock.
- SignalExecutor starts the task of each signal through a HelperTaskTracker of its own. runDrain() calls `signals.awaitNoTask()` after the pass wait and before the helper wait (the idle action of a compaction starts its wake in the task of a signal). The work of a signal calls no close and waits for no drain, and close closed the executor, so no deadlock.
- wakePump() does nothing after close began (isClosed): no pump starts after close began.

## Review Findings (2026-10-14 18:43)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift:172` `reuse/reuse` — awaitNoOpenPass repeats the wait-until-condition loop that awaitNoOpenSubmission already uses: read changeCount, return or wait for the next change, repeat. Two copies of this loop will drift apart, and a fix to one will not reach the other. Add one helper on ChangeSignal, for example `func wait(untilNil condition: () -> Bool) async -> Bool`, that runs the changeCount / waitForChange loop and returns false on cancel. Build awaitNoOpenPass on it as `await passEnds.wait { openPassCount == 0 }`, and move awaitNoOpenSubmission onto it too, so the loop lives in one place. If the helper is not added, state in the doc comment why the two loops must stay separate. Their cancel results differ: one returns, the other throws.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:165` `hand-check/close-releases-profile` — close() does not wait for the stall watchdog task (`Task { await self.watchGenerationForStalls(id:) }`, Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift:847) or for the pass-report reader task (`openGenerationPassReports(callID:)`, Sources/FoundationModelsRouter/Session/RoutedSessionActorPassReports.swift:32). The pump cancels these tasks in its `defer`, but nothing waits for them to end. Each task keeps a strong reference to `self` (RoutedSessionActor). The actor keeps `profile` (LanguageModelProfile), the profile keeps `standard` and `flash` (RoutedLLM), and each RoutedLLM keeps its `residencyHolds`. Thus close() can return while a task of the session still holds the profile, and the next resolve can see a full model pool. The implementer comment says the same: "a check of the pool footprint after a drop of the session is not deterministic". Make close() wait until these two tasks have ended (keep their Task handles on the actor and await them in runDrain after the pump ended), or make them hold no strong reference to the session.
- [x] `Tests/FoundationModelsRouterTests/SessionDrainTests.swift:314` `hand-check/close-releases-profile` — The test checks only `ModelHandleLease`, which the test itself makes and keeps in `DetachedGeneration`. It does not check the requirement of the third subtask: "After close() returns, no reference of the session holds the profile". Add a fixed-order check with no time: after close() returns and the test drops the session, a weak reference to the session (or to the RoutedLLM of its profile, when the fixture keeps no other strong reference) is `nil`. Without the fix of the finding above, this check must fail and must not hang.

## Review Findings (2026-10-14 19:05)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Concurrency/ChangeSignal.swift:123` `hand-check/reuse` — The new doc of `waitUntil(isolation:_:)` says "This is the one wait loop over a change signal, so each wait for a state uses it". This is not true. Two other loops still read `changeCount` and call `waitForChange(after:)` themselves: `waitForTheRealCallsOfTheRound(ofNoOpCallOf:)` (Sources/FoundationModelsRouter/Session/NoOpToolCallStop.swift:39-48) and `awaitIdle()` (Sources/FoundationModelsRouter/Session/RoutedSessionActorIdle.swift:31-39). Move the no-op round wait onto `waitUntil` (the condition is `noOpToolCallStop != nil || noOpToolCallRound.isComplete`, and the stop check comes after the wait). `awaitIdle()` reads its state with `await isIdle()`, so the synchronous condition of `waitUntil` cannot read it: give `waitUntil` a form with an async condition and move `awaitIdle()` onto it, or state this exception in the doc of `waitUntil` and correct the claim.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorDrain.swift:176` `hand-check/close-releases-profile` — The drain now waits for the helper tasks, but other tasks with a strong reference to the session can still run after close() returns, and thus keep the actor and its profile. (1) The task of a signal that runs (`SignalExecutor.run`, `Task { [self] in ... await work() }`, with `{ [self] in await runSignalWork(...) }` from `submitSignal`). A requested compaction (`compact(prompt:budget:)`) runs in this task. The drain waits only for the inner task (`activeCompaction.value`). After it, the signal task goes on: `performCompaction` resumes, then `endRequestedCompaction()`, `endPending`, and the idle actions of the executor. Nothing waits for this task. (2) The idle action of `performCompaction` starts `Task { await wakePump() }` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:321). When it runs after `runDrain()` set `drainTask = nil`, `wakePump()` passes its guard (`pumpTask == nil, drainTask == nil`) and starts a new pump (`Task.detached { await self.runPump() }`) after close() returned. (3) `mail(_:)` starts `Task { await self.mailDidArrive() }` (Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:51) after its put. When the put comes before close() closes the queue, this task can run after close() returned, and it also calls `wakePump()`. Thus the claims of this change are not true: "no work of the session runs" (Sources/FoundationModelsRouter/Session/RoutedSession.swift:630) and "after close() returns, no task of the session keeps its profile" (Tests/FoundationModelsRouterTests/SessionDrainTests.swift:346). Make close() wait for the signal task that runs (for example, a wait for the last task of `SignalExecutor` after its close), and make `wakePump()` start no pump after close (check `isClosed`). Or make these tasks keep no strong reference to the session. Add a fixed-order test with no time: a requested compaction holds at a gate, close() runs, the gate opens, and after close() returns and the test drops the session, a weak reference to the profile is `nil` and no pump started.

## Review Findings (2026-10-14 19:31)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:47` `duplication/duplication` — The two-line refusal cleanup repeats inside mail(_:). The catch branch at line 47 and the duplicate-id branch at line 52 both run arrival.cancel() and then withdrawRefusedMail(mail.id, subscription: key, madePending: madePending). The copies must stay in step: a later edit that changes one cleanup and not the other would leave a reserved helper count or a pending record behind on one refusal path. This is a small copy, so the severity is low. Make one local refusal helper that takes the error, or call a single private method that runs arrival.cancel() and withdrawRefusedMail(...) and then returns. Each branch then keeps only its own throw, for example `throw refusal(error)` in the catch branch and `throw refusal(MailRefusal.duplicateID(mail.id))` in the duplicate branch.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:52` `duplication/duplication` — The same two-line refusal cleanup as at line 47 repeats here. This is the second copy of the pair in mail(_:). See the finding for line 47. Share the cleanup with the catch branch at line 47, as described in that finding. Keep only the throw at this site.
