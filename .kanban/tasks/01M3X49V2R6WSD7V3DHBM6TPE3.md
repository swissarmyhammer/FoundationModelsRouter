---
comments:
- actor: wballard
  id: 01m3x6gtkr31ra1txdm9k3gm3z
  text: |-
    Research done (implement step).

    - The idle state is spread over three actors: the session actor (pumpTask, drainTask, outbox.messages, compactionRequests), the outbox actor (pending mail events) and the Extras RunPlane actor (open runs, settled tokens). The RunPlane is an Extras actor with no start notification, so the session cannot read all checks with no suspension at all.
    - Design: the session reads the RunPlane and the outbox, then reads its own state again with no suspension point, and compares lastWorkId. Only pump work starts a run, and each answer or compaction takes a new lastWorkId, so an unchanged id and no pump at both ends prove that the snapshot is consistent.
    - Order of a run end (Extras ToolRun/RunEventFunnel): the funnel stages the terminal in the outbox (and mailArrived wakes the pump) BEFORE RunPlane.settle removes the run, and deliver(settledTerminal:) comes after. So: read open runs first, then settled tokens, then the mail. In the window between settle and deliver, the staged terminal plus its settled token makes SessionOutbox.canStartASubmission true, so the check says busy.
    - Waits: a Mutex-backed change signal (no polling). The actor signals at pump end (runPump exit), at deliver(settledTerminal:), at drain end and at close start. A cancel resumes the wait at once from the cancel handler.
    - close(): ends every wait with false at its start. A wait that starts after close returns the result of one check and does not wait.
    - Test 3 (a run that settles inside the running answer, no mail answer) uses a background tool with inlineSettleGrace: the run settles inside its own tool call, the runner withdraws the staged terminal, and no mail answer starts.
    - Optional parts 2 (SessionEvent.idle) and 3 (backgroundRuns()) are not done: a new SessionEvent case breaks hosts with a total switch.
  timestamp: 2026-10-02T02:19:02.136216+00:00
- actor: wballard
  id: 01m3x73arscyezcmvbhjmga5r8
  text: |-
    Implementation landed (TDD: the new suite failed to compile with no idleChanges/awaitIdle, then passed).

    - RoutedSession.awaitIdle() is a new protocol requirement; RoutedSessionActorIdle.swift implements it. ChangeSignal (Concurrency/ChangeSignal.swift) is a Mutex-backed broadcast: a change count plus continuations. A cancel handler resumes a wait at once with false. No polling, no timer.
    - Signals: runPump exit, deliver(settledTerminal:), runDrain end, close() start (endIdleWaits sets isClosed). awaitIdle first calls attachOutboxJournalIfNeeded so the RunPlane settlement observer is always installed.
    - Deviation to note for review: the card asks for all checks with no suspension point. The RunPlane and the outbox are separate actors, so isIdle() reads them with awaits (open runs, then settled tokens, then mail), and then reads the session state again synchronously, comparing lastWorkId. This is equal to an atomic read because only pump work starts a run and each answer/compaction takes a new lastWorkId.
    - Optional parts 2 and 3 not done (SessionEvent.idle breaks total switches; backgroundRuns() not needed by the consumer).
    - Consumer note: FoundationModelsACPAgent Tests/FoundationModelsACPAgentTests/Support/CloseCountingRoutedSession.swift conforms to RoutedSession, so it needs an awaitIdle() when ^64pav2a adopts this Router revision.
  timestamp: 2026-10-02T02:29:08.505852+00:00
- actor: wballard
  id: 01m3x73bv8hkzxtaepqzp56961
  text: |-
    ### implement — changed
    - evidence: 12 files — Sources/FoundationModelsRouter/Concurrency/ChangeSignal.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActorIdle.swift (new), Sources/FoundationModelsRouter/Session/RoutedSession.swift, RoutedSessionActor.swift, RoutedSessionActorPump.swift, RoutedSessionActorRunJournal.swift, RoutedSessionActorDrain.swift, RoutedSessionActorForking.swift, FoundationModelsRouter.docc/RoutedSession.md, Tests/FoundationModelsRouterTests/SessionIdleWaitTests.swift (new, 6 tests), Tests/FoundationModelsRouterTests/Helpers/BackgroundingBackendFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift. swift build exit 0; swift test exit 0: 1463 tests in 184 suites passed (2 known issues, both pre-existing withKnownIssue), plus 23 and 19 in the other targets; no new warnings in Sources or Tests.
    - next: review
  timestamp: 2026-10-02T02:29:09.608807+00:00
- actor: wballard
  id: 01m3x75xqc31wwdvm8p96n2jxk
  text: |-
    ### review — stuck
    - evidence: The review engine did not run on commit 0a1b314e (HEAD~1..HEAD). Route 1: the MCP review tool of the reviewer session resolves the range in the FoundationModelsACPAgent repository; it ignores a cwd argument, and it gives 'revspec 0a1b314e not found'. Route 2: 'sah tool review sha review --sha HEAD~1..HEAD' in this repository gives error -32603: the CLI route has no agent factory, so the review ops cannot run. No findings are recorded. The task stays in review.
    - next: A person must start the review from a session whose sah MCP server has this repository (FoundationModelsRouter) as its working directory, then run /review ^bm6tpe3 HEAD~1..HEAD again.
  timestamp: 2026-10-02T02:30:33.452345+00:00
- actor: wballard
  id: 01m3xb1y9093svyajvrfdag7qn
  text: |-
    Review findings of 2026-10-02 done. What changed, and the mutation checks.

    1. awaitIdle() returns false at entry when isClosed is set (close() sets it at its start), the loop also stops on isClosed, and a check that says idle returns `!isClosed`. RoutedSession.awaitIdle() doc and the card "What to do" item now say: a call after close() started, also after close() returned, returns false at once. New test `aCallAfterCloseGivesFalse` failed before the fix (awaitIdle() gave true), and passes after it.
    2. Verified in the FoundationModelsExtras checkout: ToolRun.settle calls RunEventFunnel.settleRun, which awaits the post of the terminal to the sink (the outbox stages it synchronously in post), and only then does the body return; RunPlane.settleByItself settles after the body returns. The drain sweep is the one case where the terminal is staged after the settlement (sweep settles; the cancelled body posts later; runDrain joins the bodies and holds the mail; drainTask is set during that time). The deliver(settledTerminal:) comment and the readRunsAndMail()/isIdle() comments now state this. New test `theFunnelStagesTheTerminalBeforeTheSettlement` (SessionMountCompositionTests) uses a RunPlane + SessionOutbox with no mail observer (no pump) and a settlement observer probe that reads outbox.pending().events at settlement.
    3. isIdle() is internal. It is split: isIdle() = first read + readRunsAndMail() (returns IdleReads) + isIdle(startedAt:reading:) (second read, synchronous). New tests: (a) anUnheldSettledTerminalIsWork, (b) aHeldSettledTerminalIsNoWork, (c) aNewAnswerBetweenTheReadsIsWork, plus (d) aPumpAtTheSecondReadIsWork for the second hasNoPumpWork check. (a)/(b) use trackFakeRun (@_spi(Testing) RunPlane.start) and a session that never attached its observers, so no pump starts.
    4. ChangeSignalTests (4 tests) and SessionIdleWaitTests.aCallInACancelledTaskGivesFalse. A shared test helper Helpers/RecordedWaitResult.swift replaces SessionIdleWaitTests.IdleWaitOutcome, so a wait that never returns fails at the .timeLimit and does not hang the run.

    Mutation checks (mutate, build, run the suite, restore; git diff showed each restore exact):
    - remove `!canStartASubmission` term from isIdle(startedAt:reading:) -> (a) fails (also two older tests).
    - drop `!$0.isHeld` in SessionOutbox.canStartASubmission -> (b) fails (and heldMailCountsAsIdle at the time limit).
    - remove `lastWorkId == workId` -> (c) fails.
    - remove the second `hasNoPumpWork` -> (d) fails.
    - ChangeSignal: remove the `changeCount != seen` check -> change-first test fails; remove the in-lock Task.isCancelled check -> cancel-before-registration test fails at once (waiterCount 1, result true); onCancel does not remove the waiter -> cancel-after-registration test fails at the time limit; signal() resumes one waiter only -> several-waiters test fails at the time limit.
    - Extras checkout ToolRun.settleRun posts no terminal -> the funnel test fails (probe reads false); checkout restored with git checkout, status clean.

    What did not work: the first ChangeSignalTests version awaited `task.value`; under the "no in-lock cancel check" mutation the waiter registered after its onCancel ran, and the run hung past the .timeLimit (the test task awaited an unstructured task). The RecordedWaitResult + AwaitedCondition shape fixes that.

    The build-system line `warning: missing creator for mutated node: (...mlx-swift_Cmlx.bundle/Contents/MacOS)` is old: it is in the build logs from before this change. No compiler warning in Sources or Tests.
  timestamp: 2026-10-02T03:38:17.248186+00:00
- actor: wballard
  id: 01m3xb1zh7qtbszvhfcpx19a7e
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorIdle.swift, RoutedSession.swift, RoutedSessionActor.swift, RoutedSessionActorRunJournal.swift; Tests/FoundationModelsRouterTests/SessionIdleWaitTests.swift (+6 tests), SessionMountCompositionTests.swift (+1 test), ChangeSignalTests.swift (new, 4 tests), Helpers/RecordedWaitResult.swift (new). swift build exit 0; swift test exit 0: 1474 tests in 185 suites passed (2 known issues, both old withKnownIssue), plus 19 and 23 in the other targets; no new warnings. Mutation checks: each of the 4 isIdle terms, the 4 ChangeSignal paths and the Extras funnel post made its test fail, and each was restored.
    - next: review
  timestamp: 2026-10-02T03:38:18.535672+00:00
position_column: doing
position_ordinal: '80'
title: 'A host cannot know when a session is idle: add RoutedSession.awaitIdle(), so a prompt can wait for a backgrounded run''s mail answer'
---
## Problem

A host cannot know, from the public API, when a session has no more work: no background run open, and no mail-delivery answer to come. The ACP agent (FoundationModelsACPAgent card ^64pav2a) needs this to keep an ACP prompt open until the result of a backgrounded run reaches the model.

Evidence: SWE-bench run of 2026-10-01, `django__django-14608`. A `runCode` snippet went pending. The model obeyed "End your answer now; the result comes back to you as a new message". The caller stream of `streamEvents(to:maxTokens:)` ended, as its contract says. The agent sent `end_turn`. The result came as a mail-delivery answer that only `streamSessionEvents()` sees, after the client closed the session; the close cancelled the runs. The instance ended with an empty patch.

## Why the host cannot do it now

- `RoutedSessionActor.mailbox` (the `RunPlane`) and `RoutedSessionActor` are internal. Only a tool body reads the runs, through `ToolContext.backgroundRuns()`.
- `SessionAnswer.toolInvocations` keeps open records only for the runs of its own chain. `messageQueueDepth()` and `pendingMessages()` do not include the mail-delivery letter. `SessionProjection` ignores `runSettled`.
- The pump decides inside the actor (`mailArrived` -> `wakePump` -> `runNextAnswer` -> `answerMail`). Between `runSettled` and the `submissionStarted` of the mail answer, an observer sees no run and no answer. A run that settles near the end of an answer can go into that answer or start a mail answer, and the event order does not tell which.
- A host that keeps its own set of open runs and guesses copies Router state and has a race.

## What to do

1. Required: `func awaitIdle() async -> Bool` on `RoutedSession`.
   - Returns `true` when these are all true, read together on the session actor with no suspension point between the checks: no background run is open; no pump work runs or waits; no waiting mail can start a submission by itself (mail held by `mailDeliveryPaused` counts as idle).
   - Returns at once when the session is already idle.
   - Returns `false` at once when the calling task is cancelled (the same rule as `drain()`), so that `session/cancel` ends the wait.
   - `close()` ends every wait with `false`, and never hangs. A call after `close()` starts (or after it completes) returns `false` at once.
2. Optional: a session-scoped `SessionEvent.idle` on `streamSessionEvents()`, after the `answered`, `answerFailed` or `mailDeliveryPaused` of the last answer.
3. Optional: `func backgroundRuns() async -> [BackgroundRun]` on the session.

## Tests

- No run: `awaitIdle()` returns `true` at once.
- A pending run, then its mail answer: `awaitIdle()` returns `true` only after the `answered` of the mail answer.
- A run that settles inside the answer that is running: no mail answer, and `awaitIdle()` returns `true` after that answer.
- Cancellation of the waiting task: returns `false` at once.
- `close()` during a wait: the wait returns, no hang.
- A paused mail delivery counts as idle.

## Consumer

FoundationModelsACPAgent ^64pav2a: `PromptExecution.drive` subscribes to `streamSessionEvents()` before `streamEvents`; when the caller stream ends, it keeps projecting the session events until `awaitIdle()` returns, then maps the stop reason from the last answer. #generation-queue

## Review Findings (2026-10-02)

- [x] 1. RoutedSessionActorIdle.swift `awaitIdle()` (lines ~20–32) vs RoutedSession.swift `- Returns:` text (~422–423): the doc says it returns false when close() started, but a call after close() completes returns true (isIdle() runs before the isClosed guard). Make it return false at entry when the session is closed (or closing), make the doc and the card agree, and add a test that calls awaitIdle() after close() returns and asserts false.
- [x] 2. RoutedSessionActorIdle.swift `isIdle()` comment and read order (~55–79) and RoutedSessionActorRunJournal.swift `deliver(settledTerminal:)` comment (~104–106): isIdle is correct only if the funnel stages the terminal before RunPlane settles the run, but the deliver comment says "The funnel can stage the terminal before or after this call". Correct the comment (the drain sweep is the only case where the terminal is staged after the settle, and the drain holds that mail), state the invariant in the isIdle comment, and add a Router test that fails if a funnel run settles before its terminal is staged (e.g. an observer of the settlement asserts the run's terminal is already in outbox.pending().events).
- [x] 3. SessionIdleWaitTests.swift: no test drives the check into the window between settle and wakePump, or a pump that starts and ends during the reads; the six tests can pass with the `canStartASubmission` term or the `lastWorkId == workId` / second `hasNoPumpWork` checks removed, and `heldMailCountsAsIdle` passes with no mail check. Make `isIdle()` internal for @testable tests and add schedule-independent tests: (a) no pump, an unheld `.completed` terminal staged in the outbox and its token settled in the mailbox (use `@_spi(Testing) RunPlane.start` or the existing test plumbing) → isIdle() false; (b) the same terminal held → true; (c) lastWorkId changes between the two reads of the session state → false. Verify each new test fails when its guarded term is removed (mutate, run, restore) and say so in the card comment.
- [x] 4. ChangeSignal.swift `waitForChange(after:)` (~52–77) has no tests. Add ChangeSignalTests with one deterministic test per path: a change between reading changeCount and waitForChange returns true at once; a cancel before registration; a cancel after registration (waiter removed, waiterCount back to 0); one signal() resumes several waiters. Check waiterCount after each. Also add to SessionIdleWaitTests: awaitIdle() in a task cancelled before the call while a run is open → false and idleWaitCount == 0.