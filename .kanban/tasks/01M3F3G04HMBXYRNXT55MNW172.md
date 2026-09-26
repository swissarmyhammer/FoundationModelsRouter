---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3fpncfr65ba2a2r2wv4ngc7
  text: |-
    Research: the gap is real.

    - Before this change, `sendAndAwaitAnswer` called `await enqueue(message)` and then `awaitAnswer(of:)`. `withTaskCancellationHandler` runs `onCancel` at once for a task that is already cancelled, but only when the call starts. That call came AFTER `enqueue`. So the immediate handler does NOT close the gap: an already-cancelled caller put an unmarked message in `outbox`, and the mark came only after the caller got the session actor back from `outbox.add`.
    - Between those two points the session actor is free. The pump can take the message (`takeSubmissionBatch` or `takeJoiningBatch`) and read the marks (`liveMessages`) only if its job on the session actor runs before the resume job of the caller. At equal priority the jobs of an actor run in order, and the take of the pump reaches `outbox` after the `add`, so the caller resumes first. The pump gets ahead only when the executor runs a job of higher priority first (for example a caller with a lower priority than the pump). This agrees with the task description.
    - Compaction (`compact`) has no gap: `pendingCompactions.append`, `wakePump` and the handler run with no suspension point between them.

    Forced order: I found no way to force the pump-first order in a test without a test seam in production code. The only window is the hop of the caller back from `outbox`, and the order of that hop and of the pump is up to the executor. A caller that cancels itself before it calls `respond` is deterministic, but it does not show the old defect: with the old code, the handler also ran before the pump could take the message (equal priority). I wrote that test first and it PASSED on the old code (0.009 s). So the TDD red step was not possible for this change. I record this here and do not claim a red run.
  timestamp: 2026-09-26T20:31:46.680942+00:00
- actor: claude-code
  id: 01m3fpnmef5j8kd7r934a502qn
  text: |-
    Decision: the change is worth it without a forced-order test. It costs a few lines, adds no lock and no state, and removes the order dependency by construction: the handler is installed before the message exists in `openMessages` or `outbox`. After the change, every cancel of the caller sets the mark synchronously, before the message reaches `outbox` (cancel before the call) or at the time of the cancel (cancel during `enqueue`). The pump reads the mark in `liveMessages`, and `isWorkCancelled` reads it for a message that the pump already took.

    Implementation (`Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift`):
    - `awaitAnswer(of:)` is replaced by `enqueueAndAwaitAnswer(of:)`. `enqueue(message)` now runs inside the `withTaskCancellationHandler` operation.
    - After `enqueue`, if the mark is set, the operation calls `cancel(message:)` itself. Reason: the handler withdraws the message in an unstructured `Task`, and that task can run before the message is in `outbox` (for example while the first `enqueue` of a session waits in `attachOutboxJournalIfNeeded`). Then the withdraw finds nothing, and the caller would wait until the pump drops the message. When the pump already dropped it, `cancel(message:)` returns `.alreadyAnswered` and does nothing. When the pump already took it into the running answer, `cancel(message:)` stops that answer, the same as the handler task does.
    - The handler itself is unchanged: mark first, then `cancel(message:)` in a task.

    Test (`Tests/FoundationModelsRouterTests/AnswerCancellationEntryPointTests.swift`): `aCallerCancelledBeforeTheCallNeverReachesTheModel`. A first answer holds the pump inside the model. A second task cancels itself (`withUnsafeCurrentTask { $0?.cancel() }`) and then calls `respond`. The test expects `CancellationError` while the first answer still holds the pump, `outbox.waitingMessageCount == 0`, the model entered only for the first prompt, the record `[.session, .prompt, .response]`, and a follow-up answer that completes. It can fail: if the message waits for the pump, the wait ends at the `.timeLimit` of the suite; if the message reaches the model, `entered` and the record change.
  timestamp: 2026-09-26T20:31:54.831583+00:00
- actor: claude-code
  id: 01m3fppaf5tkt2ajd01h5k7pzw
  text: |-
    ### implement — changed
    - evidence: gap real (an already-cancelled caller got its mark only after `enqueue`; the pump can read the marks first only through priority reordering of actor jobs). Files: Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift (`enqueueAndAwaitAnswer(of:)` replaces `awaitAnswer(of:)`), Tests/FoundationModelsRouterTests/AnswerCancellationEntryPointTests.swift (`aCallerCancelledBeforeTheCallNeverReachesTheModel`). `swift test`: 1462 + 17 + 19 = 1498 passed, 0 failed (2 known issues are the existing deliberate ones in RealModelHarness and BoundedWait tests); no compiler warnings from project sources. Stress: 12 parallel `swiftpm-testing-helper` processes x 60 repetitions of `AnswerCancellationTests` (27 tests), all passed. TDD red was not possible: the new test passes on the old code, because no test can force the pump-first order without a production seam.
    - other findings: none. `compact` has no such gap (append, wake and handler install have no suspension point between them).
    - next: review
  timestamp: 2026-09-26T20:32:17.381317+00:00
- actor: claude-code
  id: 01m3fq3ybxdwyy8fjtfn4rwhq0
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9f50b68). 0 findings, 0 confirmed, 0 refuted. 7 validator runs attempted, 0 failed. The review examined 2 files. The .reviewignore rule excluded 2 .kanban files.
    - next: The task moved to done.
  timestamp: 2026-09-26T20:39:43.741109+00:00
- actor: claude-code
  id: 01m3fq679ng8mscwfk03gvpcyg
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — enqueue inside the cancellation handler's operation; 1 new test (it also passes on the old code; the old failure needs a priority order that no test can force without a production hook)
    - test: green — swift test, 1498 passed (1462+17+19), 0 failed, 0 skipped; 4 cancel and pump suites 3 extra runs clean
    - commit: 9f50b68
    - review: clean — 0 findings
  timestamp: 2026-09-26T20:40:58.421466+00:00
position_column: done
position_ordinal: ffffff9c80
title: Install the caller cancel handler before a message reaches the outbox
---
## What

Found during ^cx1type. `sendAndAwaitAnswer` (RoutedSessionActorGeneration.swift) calls `await enqueue(message)` and only after that enters `awaitAnswer(of:)`, which installs the cancel handler that sets the mark (`PumpAnswer.requestCancel()`).

`enqueue` suspends on `outbox.add(message:)`. When the pump already runs, it can take the message from the outbox and start its answer before the caller task gets the session actor back and installs the handler. A `Task.cancel()` of the caller in that window sets only `Task.isCancelled` of the caller. The mark comes later, when the handler is installed. After ^cx1type, `isWorkCancelled` reads the mark, so the answer stops at its next model call after the handler runs. The pump can get ahead of the caller only when the actor runs its jobs before the caller's job, for example when the caller has a lower priority than the pump.

## Why it is separate

No test can force this order: the caller and the pump both wait for the same actor, and the order of their jobs is up to the executor. ^cx1type needed a test that forces the order, so it did not change this.

## Proposal

Put `enqueue` inside the `withTaskCancellationHandler` operation, so the mark is set synchronously for any cancel after the message exists. Then handle a mark that is set before `openMessages` has the message: after `enqueue`, if the mark is set, call `cancel(message:)`, so the message is withdrawn at once and does not wait for the pump to drop it.

## Decision

The gap is real, also for a caller that is already cancelled: the immediate run of `onCancel` came after `enqueue`. The change is worth it without a forced-order test: it is small, adds no lock and no state, and removes the order dependency by construction (the handler is installed before the message exists). See the comments for the analysis.

## Acceptance

- [x] Decide if the change is worth it without a forced-order test, and write the decision here. (Proof: the Decision section above and the task comments.)
- [x] If yes: the change, and a test for the pre-registration cancel (the caller gets `CancellationError` at once and the model does not run). (Proof: `enqueueAndAwaitAnswer(of:)` in RoutedSessionActorGeneration.swift; test `aCallerCancelledBeforeTheCallNeverReachesTheModel` in AnswerCancellationEntryPointTests.swift; `swift test` 1462 + 17 + 19 = 1498 passed.) #test-flake