---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cyv20qy3j473dkftsnzz1q
  text: 'Note from the design task ^jdp02p for step 6. In ^1psqdm9 the wait-cycle check is in the submit of the queue: a child `respond` then submits on the task of the tool, which carries the OPEN `ModelCallMark`. After this task, the pump of the child session submits on its own task, which inherits no task-local. So the check must move to the helper that waits for an answer: `respond(to:)` (and each stream helper) throws `GenerationQueueError.waitInsideOpenSubmission` at once when the calling task has an OPEN mark whose queue is the queue of the target session. This covers the own session and every other session over the same model. Keep a test for both cases. Design: `generation-queue.md` section 5.5, rule 2.'
  timestamp: 2026-09-25T18:56:57.879281+00:00
- actor: claude-code
  id: 01m3dkyretjxne147emaa2spjt
  text: |-
    Picked up. Research done. Baseline at HEAD 2957b3a: `swift test` 1428 + 4 + 19 = 1451 green.

    What holds the session now:
    - `turnLock` (`AsyncSemaphore`) is taken in `beginTurn()` by three callers: `generate(...)` (respond, streamResponse, streamEvents), `dispatchNextPrompt()`, and the caller compaction `compact(prompt:budget:)`.
    - `respond(to:)` drains the run plane after its turn (`settleBackgroundRuns`, `runPlaneDrainWaitGates`, `drainedRunContinuationPrompt`, `cancelRequestCount`).
    - The cancel predicate is `isTurnCancelled` (`Task.isCancelled` or `cancelRequestedTurnId == currentTurnId`). Its read sites: `runCancellableModelCall`, the compaction abandon, `noteToolResult`, `takeCompactionYield`, `compactsAfterCeilingStop`, `noteRepetition`, `takeRepetitionStop`.
    - The five continuations already make a new SDK call, so each is already a new submission at the back of the model queue. They do not yet take the waiting messages.
    - Tests that read `turnLock` directly: HumanWaitGateTests (46 reads), AsyncSemaphoreTests (keeps: the type stays for other code), TurnCancellationTests, NestedGenerationReentryTests. Tests that depend on the run-plane drain: RespondRunPlaneDrainTests and several helpers.

    Plan decisions (reasons in the next comment when the code lands).
  timestamp: 2026-09-26T01:05:59.258966+00:00
- actor: claude-code
  id: 01m3dqmc0kfqvet0jmfdqkm75c
  text: |-
    Implementation landed (not committed). Decisions and reasons:

    1. No lock. `turnLock`, `beginTurn()`, `endTurn()`, `refuseReentryOntoThisSession`, `SessionReentryError` (its one case `sameSessionTurnInFlight`), `generate(...)` and the run-plane drain (`runPlaneDrainCount`, `runPlaneDrainWaitGates`, `cancelRequestCount`, `RunPlaneDrainWaitOutcome`, `drainedRunContinuationPrompt`) are gone. `rg AsyncSemaphore Sources/FoundationModelsRouter/Session` finds nothing. (`isInsideOwnTurnToolCall` was already gone since ^dpn2ytt.)
    2. New files: `Session/SessionMessage.swift` (`PumpAnswer<Value>` = a `RaceGate` for the one result plus an `Atomic<Bool>` cancel mark; `MessageReader`; `SessionMessage`; `SubmissionOptions`; `SubmissionBatch`) and `Session/RoutedSessionActorPump.swift` (the pump). `RoutedSessionActorTurnGating.swift` became `RoutedSessionActorCancellation.swift` (git mv). The `Atomic` in `PumpAnswer` and the `Mutex` inside `RaceGate` are synchronous state guards with no wait across a suspension point: state protection, not a lock. A caller waits only for the answer of its own message.
    3. The pump is `Task.detached` (inherits no task-local, so an OPEN `ModelCallMark` of a tool body that woke it never reaches a submission). It carries the caller's `ServiceContext` on the message and binds it around the answer, so the span keeps its parent.
    4. Which messages share a submission: `SubmissionOptions` = (is it a stream, requested ceiling). A stream message (`streamResponse`, `streamEvents`) goes alone: the SDK fixes the call kind at its start, and its fragments belong to one reader. Reply messages with the same ceiling share. The grammar of the session is the same for all reply messages. The first waiting message decides the options; every waiting message that the options admit comes with it, in FIFO order.
    5. `enqueue(prompt:)` still stages a prompt that waits for the driver: `dispatchNextPrompt()` releases the front prompt as a message (it keeps its `PromptID`) and waits for its answer. Reason: ^cbhpdjy adds `send` (auto-start) and removes enqueue/dispatch; changing enqueue here would restate ~80 PromptQueue tests twice. With no queued prompt, `dispatchNextPrompt()` wakes the pump, ends the hold of held mail, and waits until the pump is idle (returns the reply of the last mail-only answer it saw, or nil), so a driver loop does not spin while the pump delivers mail. `cancel(id:)` also withdraws a released prompt that still waits for the pump (its dispatch caller gets `CancellationError`).
    6. Mail: only the terminal of a settled BACKGROUND run (token in `SessionMailbox.settledRunTokens()`, new) starts a submission by itself. Other mail (progress, elicitation, the terminal of an in-band run that ended abnormally) rides the next submission. Reason: `ToolRun.settleRun` posts a `.completed` terminal for an in-band failure too; with it as a trigger, a scripted model that calls the failing tool in each submission looped forever (`ToolCallFailureTurnTests`). Both the funnel post (`SessionMailObserver.mailArrived()`, new) and the mailbox settlement (`deliver(settledTerminal:)`) wake the pump, because either can come first.
    7. Hold (step 8): mail that a submission gave back is held PER EVENT (`SessionOutbox.PendingEvent.isHeld`, set by `requeue(event:)`); a held terminal starts no submission by itself and rides the next one. `cancelCurrentTurn()` calls `holdPendingMail()` first, so the waiting mail stays in the outbox (step 7). What did not work: a session-wide hold flag cleared by `mailArrived()` — the late notification of the SAME mail (the post notifies after its journal write, and the pump can take the event in between) cleared it and retried the failed delivery once (seen in 16 x 100 stress).
    8. Continuations (step 4): `runTurnAttempt(isContinuation: true)` for the compaction yield, the ceiling stop, the rejected-call retry, the overflow retry and the repetition recovery. It first takes the waiting mail and every caller message the options of the answer admit (`takeMessagesJoiningTheAnswer()`); the texts go after the continuation text, joined by `messageSeparator` ("\n\n"); those callers get the final reply of the chain. The overflow target measures the retried prompt without the joined texts (the join happens at the start of the attempt, so the attach-or-requeue rule of that attempt covers the joined mail).
    9. Cancel (step 7): one predicate `isWorkCancelled` (renamed from `isTurnCancelled`, 5.9 "keep, renamed"), one read site of `cancelRequestedWorkId`. The pump sets the tentative work id BEFORE it awaits the outbox take (`PumpWork.Kind.taking`), so a cancel during the take reaches the answer. A cancelled caller marks its message (`requestCancel()`) before it asks the session to withdraw it; the pump reads the mark in the same actor turn in which it makes the message part of its work. A caller cancel whose message is in the running answer cancels that answer (as `cancelCurrentTurn()` does).
    10. The wait-cycle refusal moved to the task of the caller: `refuseWaitInsideOpenSubmission()` in `respond`, both stream helpers, `dispatchNextPrompt()` and `compact()`. It refuses an OPEN mark of the same session (also over a stub backend with no queue) and an OPEN mark on the queue of the model, with `GenerationQueueError.waitInsideOpenSubmission(model:)`.
    11. `compact(prompt:budget:)` is work of the pump (`CompactionRequest`), run between two submissions; a caller cancel withdraws a waiting request or stops the running one.
    12. The per-answer limits (`compactionYieldsStopped`, `recoveriesThisTurn`) now reset when the pump starts a new answer; the tests for them belong to ^5d0qx1b.

    Names that ^cbhpdjy / ^x7cxsg3 / ^f33q8gw own were not renamed (`cancelCurrentTurn`, `TurnID`, `TurnStart`, `turnStarted`, `dispatchNextPrompt`).
  timestamp: 2026-09-26T02:10:13.139063+00:00
- actor: claude-code
  id: 01m3drxxjdkwbc8fx48rgwfbtr
  text: |-
    Discoveries and test restatements (no test deleted; count 1451 -> 1462):

    - Restated for the new meaning: RespondRunPlaneDrainTests (respond answers from its own submission; the pump delivers each settled run as mail; the two drain-cancel tests became "a respond does not wait for the run it started" and "a caller cancel leaves the started run running"), HumanWaitGateTests (turnLock permit counts -> `isPumpRunning` / `becomesIdle()`; a second respond waits in the outbox), NestedGenerationReentryTests (own-session in-band refusal -> `GenerationQueueError.waitInsideOpenSubmission`; background own-session ask -> gets an answer), TurnCancellationTests (a cancelled waiting respond records nothing), PromptQueueTests (delivery with no driver call; a released prompt waiting for the pump is withdrawable), SessionOutboxTests (drainForDispatch tests -> take/release/withdraw/hold/putBack tests), SubmissionQueueSpikeTests and GenerationQueueTurnTests (the pump delivers the mail; the scripted tools start work on the first call only), NestedRunTerminalForwardingTests (the journal count reads the `.toolOutput` journal entries; the delivery prompt also carries the terminal), SessionOutboxToolWiringTests (elicitation answer reaches the model in a delivery).
    - Runaway found: a scripted backend that starts a background run in each `respond` gets deliveries with no end (one test ran 250+ submissions after its assertions; it slowed the 12 x 30 stress by ~50% and made `QueuedPassStallWatchTests` fail 50 times). Fixed in the fixtures (`FirstCallFlag`, `inlineSettleGrace`, first-call-only `ToolInvokingBackend`). A real model can do the same: new task ^9bxas0w asks for a decision on a guard.
    - Fixture backends that the pump now drives while a test reads them got a `Mutex` (`BackgroundingBackend`, `ToolInvokingBackend`, the scripted backend of RespondRunPlaneDrainTests): the pump delivers mail with no caller call, so "the test reads only after the driving call returned" no longer holds.
    - Count-based spins that raced the extra hop of the pump were moved to `BoundedWait` (wall clock): `MultiTurnSessionTests.forkDoesNotWaitForAnInFlightTurn` (failed 4 in 360 under stress; HEAD shows it 1 in 360) and `ForkConcurrencyTests`.
    - Stress (12 procs x 30 reps, 34 concurrency suites), 3 rounds each, load average 22 to 27: this tree — crash signature of ^vg6bmq6 in 4/1/2 processes, one `TurnCancellationTests:1151` (known ^zr22hpd failure 1), one `QueuedPassStallWatchTests:218` (timing; 0 in 480 runs of the suite alone on this tree and on HEAD); HEAD — the same crash in 4/2/4 processes, plus `MultiTurnSessionTests:455` and `RespondRunPlaneDrainTests:389/403` flakes. HEAD was built from `git archive HEAD` in the scratchpad, not a worktree.
    - `IntegrationTests` reference none of the removed symbols (`rg`); they were not built in this step.
  timestamp: 2026-09-26T02:32:54.605393+00:00
- actor: claude-code
  id: 01m3dry6eam85v7z82rd0zq414
  text: |-
    ### implement — changed
    - evidence: new `Sources/FoundationModelsRouter/Session/{SessionMessage,RoutedSessionActorPump}.swift`; `RoutedSessionActorTurnGating.swift` -> `RoutedSessionActorCancellation.swift`; changed Session/{RoutedSessionActor, RoutedSessionActorGeneration, RoutedSessionActorTurnExecution, RoutedSessionActorCompaction, RoutedSessionActorCompactionYield, RoutedSessionActorRepetitionWatch, RoutedSessionActorRecording, RoutedSessionActorRunJournal, RoutedSessionActorGenerationCalls, SessionOutbox, GenerationReentry, RoutedSession, LanguageModelSessionBackend, OperationEventSegment, TurnIdentity}.swift, Hosting/SessionMailbox.swift, Concurrency/{AsyncSemaphore,GenerationQueue}.swift, Router.swift, Resolution/LiveModelLoader.swift, Tracing/RouterTracing.swift, docc/RoutedSession.md, generation-queue.md; tests: new SessionMessagePumpTests.swift, Helpers/FirstCallFlag.swift, plus 26 restated or re-documented test files. `swift test`: 1439 + 4 + 19 = 1462 passed (3 runs); forced rebuild: 0 warnings (only the known mlx bundle line); stress 12 x 30 x 3 rounds vs HEAD: no crash HEAD does not show (^vg6bmq6 only).
    - next: review (the task stays in `doing`). Not committed.
  timestamp: 2026-09-26T02:33:03.690742+00:00
- actor: claude-code
  id: 01m3dv9b45p5vpefmnhns8md0h
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`, 9 findings (9 confirmed, 3 refuted). RoutedSessionActorCompaction.swift:131, RoutedSessionActorCompaction.swift:245, RoutedSessionActorCompactionYield.swift:201, RoutedSessionActorGeneration.swift:158, RoutedSessionActorGeneration.swift:249, RoutedSessionActorRepetitionWatch.swift:257, SessionMessage.swift:129, SessionOutbox.swift:220, SessionOutbox.swift:226.
    - fact: The two `completeness/invariant-propagation` findings say that a symbol is not defined. Both symbols are in the tree: `cancel(compaction:)` is in RoutedSessionActorPump.swift, and `isWorkCancelled` is in RoutedSessionActorTurnExecution.swift. The implementer must examine these two findings against the code.
    - next: The implementer corrects each finding in the dated `## Review Findings` section. Then run the review again. The task stays in `review`.
  timestamp: 2026-09-26T03:14:06.085343+00:00
- actor: claude-code
  id: 01m3dvbvb94s4q00317tnd8tz1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 55 files (turnLock removed; one pump for each session)
    - test: green — swift test, 1462 passed (1439+4+19), 0 failed, 0 skipped; 26 session and queue suites 3 extra runs clean; IntegrationTests build clean
    - commit: 745e40d
    - review: findings — RoutedSessionActorCompaction.swift:131, :245 (symbols exist; the reviewer found them), RoutedSessionActorCompactionYield.swift:201, RoutedSessionActorGeneration.swift:158, :249, RoutedSessionActorRepetitionWatch.swift:257, SessionMessage.swift:129, SessionOutbox.swift:220, :226
  timestamp: 2026-09-26T03:15:28.233087+00:00
- actor: claude-code
  id: 01m3dvnjsmgag1s9y6mm41wzdb
  text: |-
    Picked up the 9 findings of 2026-09-25 21:41. Moved to doing.

    Findings 1 and 2 (`completeness/invariant-propagation`): both symbols exist, and each call is load-bearing. Proof:

    1. `cancel(compaction:)` is `func cancel(compaction request: CompactionRequest)` in `Session/RoutedSessionActorPump.swift`. Experiment: the call in `compact(prompt:budget:)` removed. Result: 2 failures in TurnCancellationTests: `cancellingACallerDrivenCompactStopsIt(route: .callerTask)` (the running compaction never stops; time limit) and the NEW test `cancellingAWaitingCallerCompactWithdrawsIt` (the waiting request stays in `pendingCompactions`; no test covered this path before). Call restored.
    2. `isWorkCancelled` is `var isWorkCancelled: Bool` in `Session/RoutedSessionActorTurnExecution.swift`. Experiment A: the read replaced with `false` (never abandon). Result: NO existing test failed. Reason: the auto compaction has two tiers, and the pre-flight check of the next tier throws `CancellationError` anyway. A caller `compact()` has one tier only, so the summarizer fault reached the caller in place of the stop. That was a coverage gap. NEW test `callerCompactFaultCoincidingWithAStopIsCancelled` fails with `.summarizerFailed of type ProbeError` under experiment A, and passes with the read. Experiment B: the guard line removed (always abandon). Result: 5 failures (`summarizerCancellationErrorWithNoStopOutstandingStillDegrades`, AutoCompactionTests flash fallback, 3 CompactionTracingTests). Guard restored.

    Each call site now has a comment that names the file and the declaration of the symbol, and the tests that prove it. No propagation gap in production code: every cancel read in the compaction path goes through `isWorkCancelled` or the per-request mark `PumpAnswer.isCancelRequested`.
  timestamp: 2026-09-26T03:20:47.156565+00:00
- actor: claude-code
  id: 01m3dvw6aczawvgc0wp3has2v1
  text: |-
    Findings 3 to 9: decisions and reasons.

    - Findings 3 and 4 (`duplication/duplication`, CompactionYield and RepetitionWatch): new `runContinuation(after:prompt:body:)` in `RoutedSessionActorTurnExecution.swift`, beside `runTurnAttempt`. It is the one place that builds a continuation from a `StoppedAttempt` (no mail, `isContinuation: true`). `compactAndContinue` and `continueAfterRepetitionStop` call it. The two continuation calls in `recoverFailedAttempt` stay as they are: they have no `StoppedAttempt`, and their arguments differ (retry prompt and retry count; `allowOverflowRetry: false`).
    - Findings 5 and 6 (`duplication/duplication`, Generation): new private `streamMessage(prompt:maxTokens:reader:)`. `streamResponse` and `streamEvents` each give only the reader case. The same cause was also in `submissionWork`: its two stream cases had the same body. New private `streamSubmissionWork(into:responseTokenCeiling:onEvent:wrapFragment:)` removes it.
    - Finding 7 (`code-hygiene/dead-code-swift`, `SubmissionOptions.requestedMaxTokens`): kept, and now read. The field is the ceiling part of the key that groups messages, so the pump reads the ceiling of each submission from it: `runAnswer` passes its `options` to `runFirstSubmission(carrying:options:mail:workId:)`, which builds `ResponseTokenCeiling(requested: options.requestedMaxTokens, ...)` (before: `first?.requestedMaxTokens`, the same value). Reason not to remove it: without it the options cannot keep two messages with different ceilings out of one submission (step 2 of the task).
    - Findings 8 and 9 (`duplication/duplication`, SessionOutbox): new private `setEventHold(_:)`. The same cause was also in `takeSubmissionBatch`, `takeJoiningBatch` and `withdrawMessages` (each copied "filter, then remove by id"). New private `takeMessages(where:)` removes it.
    - No lock was added. Nothing waits on a semaphore or a mutex.
    - New tests (TurnCancellationTests): `cancellingAWaitingCallerCompactWithdrawsIt`, `callerCompactFaultCoincidingWithAStopIsCancelled`. Count 1462 -> 1464.
  timestamp: 2026-09-26T03:24:23.756595+00:00
- actor: claude-code
  id: 01m3dvwa947dwc5v2j70m29xg5
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Session/{RoutedSessionActorCompaction, RoutedSessionActorCompactionYield, RoutedSessionActorGeneration, RoutedSessionActorPump, RoutedSessionActorRepetitionWatch, RoutedSessionActorTurnExecution, SessionMessage, SessionOutbox}.swift, Tests/FoundationModelsRouterTests/TurnCancellationTests.swift (2 new tests). `swift build --build-tests`: 0 warnings besides the known mlx bundle line. `swift test`: 1441 + 4 + 19 = 1464 passed, 0 failed (2 known issues are the designed `withKnownIssue` marks in RealModelHarnessTests and BoundedWaitTests), run 2 times. Session, pump, outbox, compaction, cancellation, prompt queue, human wait, reentry, run plane, repetition and generation queue suites: 280 tests, 4 runs, all passed. All 9 findings are checked.
    - next: review. The task stays in `doing`. Not committed.
  timestamp: 2026-09-26T03:24:27.812429+00:00
- actor: claude-code
  id: 01m3dwbfvmep4b2py0tvbyek9f
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (d6f1315), 0 findings (0 confirmed, 0 refuted; 14 attempted, 0 failed, 0 skipped). 9 source files reviewed; 2 `.kanban/` files excluded by `.reviewignore`. All 9 items of `## Review Findings (2026-09-25 21:41)` are checked. The two symbols of the `completeness/invariant-propagation` findings exist at HEAD: `func cancel(compaction request: CompactionRequest)` in Session/RoutedSessionActorPump.swift, and `var isWorkCancelled: Bool` in Session/RoutedSessionActorTurnExecution.swift.
    - next: none. The task moved to `done`.
  timestamp: 2026-09-26T03:32:45.044810+00:00
- actor: claude-code
  id: 01m3dwd9rhfcm87tg4wn1h2bnm
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 9 files (shared helpers; 2 new cancel tests; requestedMaxTokens now read)
    - test: green — swift test, 1464 passed (1441+4+19), 0 failed, 0 skipped; 240 session and pump tests 3 extra runs clean; IntegrationTests build clean
    - commit: d6f1315
    - review: clean — 0 findings
  timestamp: 2026-09-26T03:33:44.337681+00:00
depends_on:
- 01M3CYJ4VS4VF5EEHA01PSQDM9
- 01M3CYJJGNHH04AREE9DPN2YTT
position_column: done
position_ordinal: ffffff8b80
title: Replace turnLock with a per-session message queue and one pump task
---
## Why

The user decided on 2026-09-25: "i really really don't want a lock based design, i want a work queue", and the "turn" must go. `turnLock` (an `AsyncSemaphore`) holds a session from a caller's `respond`/`stream` to its final answer. A second caller waits on it, mail goes in only when a new call starts, and a tool that asks its own session gets `sameSessionTurnInFlight`. Design: `generation-queue.md`, sections 5.2, 5.4, 5.5, 5.6 and 5.8.

The SDK allows one `LanguageModelSession.respond` at a time for each SDK session (`LanguageModelSession.Error.concurrentRequests`). In the target model, one pump task for each session is the only code that submits for that session, and it submits the next item only after the result of the last one. That keeps the SDK limit with no lock.

## What to do

1. Messages: a caller prompt and mail (the pending events of `SessionOutbox`, for example the terminal of a settled background run) wait in the `SessionOutbox` of the session. Each caller prompt gets a message id and a waiter for its answer.
2. The pump: one task for each session. It starts when a message arrives and no pump runs, and it ends when no deliverable message waits (the rule of `deliverSettledRunsIfAny`: a progress or elicitation report alone does not start a submission). Each cycle: take every waiting message that can share one submission, compose one prompt (the mail preamble, then the caller prompts in FIFO order), do the proactive compaction check, call the boundary tools, and submit one item to the queue of the model. A message with its own options (a grammar or a schema, or a token ceiling that differs) goes alone in its own submission, because the SDK fixes the options at the start of a call.
3. A message that arrives while a submission runs waits in the outbox for the next cycle of the pump. It never goes into the running submission.
4. Continuations: a compaction yield, a ceiling stop, an overflow retry, a rejected-call retry and a repetition recovery each become one more submission for the same answer. Each goes to the back of the queue of the model. The messages that wait at that time go into the prompt of the continuation.
5. Answers: the final answer of a chain of submissions resumes the waiters of every caller message that the chain delivered. `respond(to:)` becomes: add a message, then wait for its answer. `respond(to:)` no longer drains the run plane: a settled run is mail, and the pump delivers it in a later submission.
6. Remove `turnLock`, `beginTurn()`, `endTurn()`, `refuseReentryOntoThisSession`, `SessionReentryError.sameSessionTurnInFlight` and `isInsideOwnTurnToolCall`. A background body may ask its own session for an answer: it waits for a later submission and does not hang. An in-band tool that waits for an answer of its own session gets the wait-cycle error of task ^1psqdm9 (the same model queue), at once.
7. Cancel: `cancelCurrentTurn()` stops the running submission of the session, removes its waiting item from the model queue, and withdraws the waiting caller messages (their waiters get `CancellationError`). Mail stays in the outbox. Key every cancel decision on one predicate with one read site, never on the type of `CancellationError` (the invariants in the memory note `routed-session-cancellation-invariants`).
8. Attach or requeue: mail that a failed or cancelled submission took goes back into the outbox when the diff has no `.prompt` entry to attach it to. Keep the rule of `recordFailedTurn(...)` before a rethrow, and the `try Task.checkCancellation()` after the stream loop.
9. `dispatchNextPrompt()` and `awaitQueuedWork()` keep their signatures in this task as thin helpers over the pump. The task "Public message API" replaces them.

## Acceptance Criteria

- [x] `turnLock` and every `AsyncSemaphore` in `Session/` are gone. No caller waits on a semaphore. <!-- proof: `rg -n 'turnLock|AsyncSemaphore' Sources/FoundationModelsRouter/Session` finds nothing; a caller waits only on the `PumpAnswer` of its own message -->
- [x] A test: while a submission of a session runs, a second `respond(to:)` on that session waits on no lock. Its prompt waits in the outbox, goes into the next submission, and each caller gets the answer of the submission that carried its prompt. <!-- proving test: SessionMessagePumpTests.aRespondDuringASubmissionWaitsInTheOutboxForTheNextSubmission (also HumanWaitGateTests.secondRespondWaitsInTheOutboxDuringAHumanWait, SessionMessagePumpTests.aContinuationCarriesTheWaitingMessages) -->
- [x] A test: mail that arrives while a submission runs goes into the prompt of the next submission, never into the running one. The next submission starts with no caller call. <!-- proving test: SessionMessagePumpTests.mailDuringASubmissionStartsTheNextSubmission (also PromptQueueTests.settledRunOnEmptyQueueRunsADeliveryTurn, RespondRunPlaneDrainTests.respondAnswersAndThePumpDeliversEachSettledRun) -->
- [x] A test: a background body asks its own session for an answer and gets it, with no error and no hang. <!-- proving test: NestedGenerationReentryTests.aBackgroundBodyThatGeneratesOnItsOwnSessionGetsAnAnswer (restated from ...IsRefused) -->
- [x] A test: an in-band tool that waits for an answer of its own session gets the wait-cycle error at once. <!-- proving test: NestedGenerationReentryTests.aToolBodyThatGeneratesOnItsOwnSessionIsRefused (expects GenerationQueueError.waitInsideOpenSubmission); another session on the same model: GenerationQueueTurnTests.anInBandWaitForABusySessionOnTheSameModelIsRefused -->
- [x] A test: a cancel withdraws the waiting caller messages (their callers get `CancellationError`), stops the running submission, and keeps the waiting mail in the outbox. <!-- proving test: SessionMessagePumpTests.aCancelWithdrawsCallerMessagesStopsTheSubmissionAndKeepsTheMail (also TurnCancellationTests.cancellingAQueuedTurnNeverReachesTheModel) -->
- [x] A test: a submission that fails after it took mail puts the mail back (no silent outbox loss), and a proactive compaction that throws records the failure and requeues its mail. <!-- proving tests: SessionMessagePumpTests.aFailedDeliveryPutsItsMailBackAndIsNotRetried; TurnCancellationTests.cancelledProactiveCompactionRequeuesItsDrainedEvents, cancelledTurnRequeuesUndeliveredEvents -->
- [x] The memory note `routed-session-cancellation-invariants` is updated for each invariant that changed (see `generation-queue.md` section 5.9). <!-- proof: memory/routed-session-cancellation-invariants.md rewritten (gone: turnLock/beginTurn/drain; kept: background mark wrap, recordFailedTurn bracket, checkCancellation; renamed: isWorkCancelled; new: detached pump, caller-task refusal, per-event hold, background-terminal-only delivery); stub-backend-producer-race.md updated -->
- [x] Full `swift test` green, 0 new warnings. The concurrency suites pass a parallel stress run with no crash that HEAD does not also show (^vg6bmq6). <!-- proof: `swift test` 1439 + 4 + 19 = 1462 green in 3 runs; forced rebuild of the package targets: 0 warnings besides the known mlx bundle line; stress 12 procs x 30 reps x 3 rounds over 34 concurrency suites: the only crash is the ^vg6bmq6 signature, which HEAD shows at the same rate (HEAD 4/2/4, this tree 4/1/2 processes) --> #generation-queue

## Review Findings (2026-09-25 21:41)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 52 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, so its declarations are unread

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:131` `completeness/invariant-propagation` — The compaction initiation (line 119-133) sets up a cancellation handler that calls `self.cancel(compaction: request)`, but no matching `cancel(compaction:)` overload exists. The only `cancel` method shown in the added code accepts `SessionMessage`, not `CompactionRequest`. This leaves the compaction cancellation path incomplete and breaks the symmetry: if a caller can initiate a compaction, the cancellation mechanism must handle it. Add a `func cancel(compaction: CompactionRequest) async` overload in RoutedSessionActorCancellation.swift to handle cancellation of pending compaction requests, or verify that the cancellation transport (line 131) calls the correct method name and type that exists elsewhere.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:245` `completeness/invariant-propagation` — The code references `isWorkCancelled` (line 245: `guard isWorkCancelled else { return }`) but this property/function is not defined anywhere in the marked additions. The change transitions from turn-based to work-based cancellation (removing `cancelRequestedTurnId`, adding `cancelRequestedWorkId`), and code that reads the cancellation status must have a corresponding property. The invariant is broken: usage without definition. Add a computed property `var isWorkCancelled: Bool { guard let workId = pumpWork?.id else { return false }; return cancelRequestedWorkId == workId }` to RoutedSessionActor, or define it as an inline check if the guard statement should use a different condition.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompactionYield.swift:201` `duplication/duplication` — The `runTurnAttempt` call at lines 198–202 is nearly verbatim identical to the call in `continueAfterRepetitionStop` at RoutedSessionActorRepetitionWatch.swift:254–258, differing only in the `ownPrompt` parameter (`continuationPrompt` vs `Self.repetitionStopContinuationPrompt`). This is one function with an argument waiting to be extracted. Extract a shared helper function that accepts the continuation prompt as a parameter and delegates to `runTurnAttempt` with the other shared values, eliminating the copy in one or both locations.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:158` `duplication/duplication` — The `sendAndAwaitAnswer` call in `streamResponse` at lines 157–158 is nearly verbatim identical to the call in `streamEvents` at lines 248–249, differing only in the `reader` parameter (`.textStream(continuation)` vs `.eventStream(continuation)`). This is one function with an argument waiting to be extracted. Extract a shared helper function parameterized by the `reader` type, eliminating the duplicate function bodies and centralizing the `sendAndAwaitAnswer` call logic.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:249` `duplication/duplication` — The `sendAndAwaitAnswer` call in `streamEvents` at lines 248–249 is nearly verbatim identical to the call in `streamResponse` at lines 157–158, differing only in the `reader` parameter (`.eventStream(continuation)` vs `.textStream(continuation)`). This is one function with an argument waiting to be extracted. Extract a shared helper function parameterized by the `reader` type, eliminating the duplicate function bodies and centralizing the `sendAndAwaitAnswer` call logic.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift:257` `duplication/duplication` — The `runTurnAttempt` call at lines 254–258 is nearly verbatim identical to the call in `compactAndContinue` at RoutedSessionActorCompactionYield.swift:198–202, differing only in the `ownPrompt` parameter (`Self.repetitionStopContinuationPrompt` vs `continuationPrompt`). This is one function with an argument waiting to be extracted. Extract a shared helper function that accepts the continuation prompt as a parameter and delegates to `runTurnAttempt` with the other shared values, eliminating the copy in one or both locations.
- [x] `Sources/FoundationModelsRouter/Session/SessionMessage.swift:129` `code-hygiene/dead-code-swift` — var.instance `requestedMaxTokens` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:220` `duplication/duplication` — holdPendingMail() and releaseHeldMail() (line 226) are nearly identical, differing only in a single boolean literal. This is a function with an argument waiting to be extracted. Extract a private helper function `private func setEventHold(_ held: Bool)` with the shared body, and have both `holdPendingMail()` and `releaseHeldMail()` call it with `true` and `false` respectively.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:226` `duplication/duplication` — releaseHeldMail() is a near-duplicate of holdPendingMail() (line 220), differing only in a single boolean literal. Extract a private helper function `private func setEventHold(_ held: Bool)` and call it from both public functions.
