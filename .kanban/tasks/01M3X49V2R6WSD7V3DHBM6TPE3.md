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
   - `close()` ends every wait, and never hangs.
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