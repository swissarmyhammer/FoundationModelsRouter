---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3d6s4ax54dyy7er16j922h6
  text: |-
    Research (implement step):
    - `GenerationQueue` has one caller in production: `QueuedLanguageModel.Executor.respond`. Test stub containers call the public `runPass(isolation:_:)` (`PooledResidencyTests`, `ForkConcurrencyTests`, `GenerationQueuePublicSurfaceTests`).
    - Tests read `availablePlaces` / `waiterCount` in 8 files: GenerationQueueTests, GenerationQueueTurnTests, SharedGenerationQueueContentionTests, ForkConcurrencyTests, RecordingLanguageModelTests, NestedGenerationReentryTests, QueuedPassStallWatchTests, PooledResidencyTests. All the spin helpers (`BoundedWait.spin`, `conditionReached`, the local `spin`) take an async condition, so async observability values fit.
    - Task-locals below the executor pass: R2 ^cc2tezn is not done in this repository (no `promptCacheScope` in Sources). The Router task-locals (`ModelCallMark`, `ToolResultAppendBoundary`, `ToolContext`) are read at the entry of a call or in tool bodies, never inside an executor pass. No span is opened inside a pass. So the pass closure binds no task-local now.
    - The old semaphore refuses a caller that is cancelled before it arrives (`cancelledOnArrival`). The worker keeps that: a submitter that is already cancelled gets `CancellationError` and its item never joins the list.
    - Trap found: `Task {}` copies the task-locals of the task that makes it. A drain task made with `Task {}` from the first submitter would give that submitter's task-locals to every later item. The worker must use `Task.detached`.
  timestamp: 2026-09-25T21:15:43.325947+00:00
- actor: claude-code
  id: 01m3d7gqrm2c55we09gbhdgagg
  text: |-
    Decisions (implement step), each with its reason:
    1. `GenerationQueue` is now a `public actor` (was `public final class` over `AsyncSemaphore(value: 1)`). Reason: design 5.3 says "an actor that holds a FIFO list". Callers keep `GenerationQueue()` and `===`, because an actor is a reference type.
    2. One worker task for each queue: `Task.detached { runWaitingItems() }`. It takes the items in FIFO order and ends when the list is empty; the next submit starts a new one. Each item runs on its own `Task.detached(priority: <submitter priority>)` that the worker makes and awaits. Reason: a cancel of a running item must reach that item only; a cancel of the worker task would reach every later item. `detached` because `Task {}` copies the task-locals of the task that makes it.
    3. The worker clears `running` before it resumes the submitter, and `worker = nil` has no suspension point after the last delivery. Reason: a submitter that has its result sees `isRunning == false` at once, so the old assertions `availablePlaces == 1` keep the same strength as `isRunning == false`.
    4. Exactly one resume: an item is either in `waiting` (only `cancel(_:)` resumes it, with `CancellationError`) or popped by the worker (only the worker resumes it, with the result of the body). Both changes happen on the actor.
    5. Cancel race: the cancel handler of the submitter runs `Task { await queue.cancel(id) }`. `submit` checks `Task.isCancelled` and appends with no suspension point between. The cancel flag is set before the handler runs, so a cancel that reaches the actor before the append is seen by the check, and a cancel after the append finds the item. Item ids come from an `Atomic<UInt64>` counter so the handler knows the id before the submitter reaches the actor.
    6. Observability: `availablePlaces` -> `isRunning` (worker task exists), `waiterCount` -> `waitingCount` (items in the list). Both are actor properties, read with `await`.
    7. `runPass(isolation:_:)` stays public, and now takes `@escaping @Sendable () async throws -> T` with `T: Sendable`, because the body runs on another task. The `onQueued` overload stays internal.
    8. No task-local is bound inside the pass closure: R2 ^cc2tezn is not done in this repository, and no Router task-local is read inside an executor pass.
    9. The "place" wording of the stall watch and `RoutedSession` docs stays for ^1psqdm9, which restates the stall watch (design 5.6). I changed the docs that describe the queue mechanism: `GenerationQueue`, `QueuedLanguageModel`, `GenerationPassObserver`, `ExecutorPassthrough`, `AsyncSemaphore` header, `ModelLoader`, `LiveModelLoader`, `SessionEvent.passQueued/passStarted`.
  timestamp: 2026-09-25T21:28:36.884816+00:00
- actor: claude-code
  id: 01m3d958w7jsacwe30fkxyxpmx
  text: |-
    Corrections to the decision record, and what did not work:
    - Decision 1 changed. `GenerationQueue` stays a `public final class GenerationQueue: Sendable`. It holds a new internal `actor GenerationWorker` (`Concurrency/GenerationWorker.swift`) with the list, the worker task and the running item. Reason: an actor method cannot take the `isolation: isolated (any Actor)?` parameter of `runPass(isolation:_:)` ("instance method with 'isolated' parameter cannot be 'nonisolated'"). The class keeps that public signature, and the public type kind does not change.
    - Decision 5 changed. The item identity is a `GenerationWorker.Ticket` (a class with one `Atomic<Bool>` cancel mark), not a counter. The cancel handler marks the ticket at once, then sends `worker.cancel(ticket)` to the actor. `waitingCount` does not count a marked item, and the worker task never starts a marked item (it withdraws it). Reason: a stress run (12 processes x --repetitions 100) failed `GenerationQueueTests.cancelledWaitingPassLeavesNoPlaceTaken` one time: `waiterCountAfterCancel == 0` was false. The SDK can end a cancelled call before the actor takes the cancel hop, so the old assertion saw the item still in the list. The old semaphore removed the waiter in the cancel handler itself. The new test `aCancelledWaitingItemLeavesTheCountWhenTheCancelReturns` failed 297 of 300 times before the change, and 17 of 300 times the cancelled item even ran. With the mark it passes 300 of 300, and the stress gives 12 of 12 green.
    - The mark is a flag, not a lock: nothing waits on it.

    Stress evidence (swiftpm-testing-helper, 12 processes at the same time):
    - Worker suites (`GenerationQueueWorkerTests|GenerationQueueWorkerTaskTests|GenerationQueueTests|QueuedPassStallWatchTests|SharedGenerationQueueContentionTests`), --repetitions 100: 12 of 12 green.
    - Queue, cancellation and stall suites (`...|GenerationQueueTurnTests|TurnCancellationTests|NestedGenerationReentryTests|PooledResidencyTests|ForkConcurrencyTests|HumanWaitGateTests|GenerationStallTests|RecordingLanguageModelTests`), --repetitions 30, compared with a HEAD dd1190a copy built in the scratchpad: new tree 6 ok / 5 failed / 1 crash; HEAD 8 ok / 3 failed / 1 crash. Every failure is in a test that also fails at HEAD, and none is in a worker or queue test: `TurnCancellationTests.swift:1154` (uses no GenerationQueue), `RecordingLanguageModelTests.swift:530` (count-based spin under load), `QueuedPassStallWatchTests.swift:213` and `PooledResidencyTests.swift:323` (HEAD only). New task ^zr22hpd records them.
    - SDK crash ^vg6bmq6 (`_ContiguousArrayStorage deallocated with non-zero retain count 2`), its own filter, --repetitions 50: new tree 4 of 12 crashed, HEAD 4 of 12 crashed. The change does not make it worse.
  timestamp: 2026-09-25T21:57:18.343674+00:00
- actor: claude-code
  id: 01m3d95fasfdzydd4mtcbjfzcy
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsRouter/Concurrency/GenerationWorker.swift, Tests/FoundationModelsRouterTests/GenerationQueueWorkerTests.swift (8 tests); changed GenerationQueue.swift, QueuedLanguageModel.swift, GenerationPassObserver.swift, AsyncSemaphore.swift (doc), ExecutorPassthrough.swift (doc), ModelLoader.swift (doc), LiveModelLoader.swift (doc), SessionEvent.swift (doc), and 8 test files for `isRunning` / `waitingCount`. `swift test`: 1415 + 3 + 19 = 1437 passed, 3 runs, 0 new warnings after a forced recompile of the root package. Stress with parallel repetitions as recorded above.
    - next: review. Follow-up task ^zr22hpd records the stress failures that also occur at HEAD.
  timestamp: 2026-09-25T21:57:24.953112+00:00
- actor: claude-code
  id: 01m3d9yfxhhjthze60sawxj5qb
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 10cae0b). 0 findings, 0 confirmed, 0 refuted. The engine examined 18 files. It did not examine 4 .kanban files because .reviewignore excludes them.
    - next: The task is in done. Task 01M3CYJ4VS4VF5EEHA01PSQDM9 was blocked by this task. It can start now.
  timestamp: 2026-09-25T22:11:04.753880+00:00
- actor: claude-code
  id: 01m3da10cx7j1ne4qaezp8793j
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — GenerationWorker actor (FIFO, one worker task, no semaphore); 8 new tests
    - test: green — swift test, 1437 passed (1415+3+19), 0 failed, 0 skipped; queue and cancel suites 3 extra runs clean; IntegrationTests build clean
    - commit: 10cae0b (fixture and Package.swift exclude: f87c7e8)
    - review: clean — 0 findings
  timestamp: 2026-09-25T22:12:27.165656+00:00
depends_on:
- 01M3A1F89ZRFMCGTNPBNJDP02P
position_column: done
position_ordinal: ffffff8880
title: Run the generation queue on one worker task for each model, not on a semaphore
---
## Why

The user decided on 2026-09-25: "i really really don't want a lock based design, i want a work queue", and "not with a lock". `GenerationQueue` (`Concurrency/GenerationQueue.swift`) is an `AsyncSemaphore(value: 1)`, and each caller waits on it. That is a lock with a queue name. Design: `generation-queue.md`, section 5.3 (the worker) and section 5.11 (the task order).

This task changes only the mechanism of the queue. The item stays one executor pass here. Task "Make one submission to Foundation the item of the generation queue" then changes the item to one whole SDK call. Two steps keep each review small, and all the tests of ^8csj2hw, ^93kjn94 and ^ake8sax stay as the proof that the new mechanism keeps the old behavior.

## What to do

1. Replace the `AsyncSemaphore` in `GenerationQueue` with a work queue: a FIFO list of items and one worker for each queue. Recommended form: an `actor` that holds the list, and one drain task that runs the items one at a time and ends when the list is empty (the shape of `SubmissionWorker` in `Tests/FoundationModelsRouterTests/SubmissionQueueSpikeTests.swift`). A submitter gives one closure and waits for the result of its own item through a continuation. It never waits on a semaphore or a lock.
2. Cancel: when the task of a submitter is cancelled while its item waits, remove the item from the list and resume the submitter with `CancellationError`. The item never runs. When the item already runs, cancel the task that runs it. Resume each continuation exactly one time, also when a cancel and the start of the item race.
3. The item runs the SDK's own executor call, not a copy: `QueuedLanguageModel.Executor.respond` submits `{ try await innerRespond(request, channel) }` with the same `request` and `channel` that the SDK gave it (both are `Sendable` in the FoundationModels interface), and waits for its result. The worker task inherits no task-local. Bind every task-local that the pass needs inside the closure. If R2 ^cc2tezn is done, its `MLXLanguageModel.$promptCacheScope` binding moves inside the closure.
4. Keep the reports of ^ake8sax: `onQueued` when the item must wait (the worker runs another item), then "started" when the worker starts the item, then "ended".
5. Keep the public `runPass(isolation:_:)` as "submit and wait for the result". A consumer stub container (the ACP decision of ^8csj2hw step 4) still uses it.
6. Replace `availablePlaces` and `waiterCount` with observability values that fit a work queue (for example `isRunning` and `waitingCount`), and update the tests that read them.

## Acceptance Criteria

- [x] `GenerationQueue` holds no `AsyncSemaphore`. A submitter waits only for the result of its own item. <!-- GenerationQueue.swift holds only a GenerationWorker actor (GenerationWorker.swift); proved by GenerationQueueWorkerTests.itemsFromThreeTasksRunInOrderWithNoOverlap -->
- [x] A test: items from three tasks run in FIFO order, one at a time, with no overlap. <!-- GenerationQueueWorkerTests.itemsFromThreeTasksRunInOrderWithNoOverlap -->
- [x] A test: a cancelled waiting item never runs, its submitter gets `CancellationError` at once, and the next item runs. <!-- GenerationQueueWorkerTests.aCancelledWaitingItemNeverRunsAndTheNextItemRuns; also aCancelledWaitingItemLeavesTheCountWhenTheCancelReturns, anAlreadyCancelledSubmitterNeverRunsItsItem, aCancelledRunningItemGetsTheCancel -->
- [x] A test with many repetitions: a cancel that races the start of an item resumes the submitter exactly one time, and the queue then runs the next item. <!-- GenerationQueueWorkerTests.aCancelThatRacesTheStartOfAnItemResumesOneTime (300 repetitions in the test; 12 processes x --repetitions 100 green) -->
- [x] A test over the scripted model: the pass runs on the worker task, and the SDK call returns the output of that pass. <!-- GenerationQueueWorkerTaskTests.thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput, with the control theSDKGivesTheCallerTaskLocalToThePass -->
- [x] The tests of ^8csj2hw, ^93kjn94 and ^ake8sax stay green. No assertion of them is weakened. <!-- GenerationQueueTests, GenerationQueueTurnTests, SharedGenerationQueueContentionTests, NestedGenerationReentryTests, QueuedPassStallWatchTests, GenerationQueuePublicSurfaceTests, GenerationPassEventPublicSurfaceTests; availablePlaces==1 -> isRunning==false, waiterCount -> waitingCount -->
- [x] Full `swift test` green, 0 new warnings. <!-- swift test: 1415 + 3 + 19 = 1437 passed, 3 runs; forced recompile of the root package shows no new warning --> #generation-queue