---
assignees:
- claude-code
depends_on:
- 01M3A1F89ZRFMCGTNPBNJDP02P
position_column: todo
position_ordinal: 8f80
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

- [ ] `GenerationQueue` holds no `AsyncSemaphore`. A submitter waits only for the result of its own item.
- [ ] A test: items from three tasks run in FIFO order, one at a time, with no overlap.
- [ ] A test: a cancelled waiting item never runs, its submitter gets `CancellationError` at once, and the next item runs.
- [ ] A test with many repetitions: a cancel that races the start of an item resumes the submitter exactly one time, and the queue then runs the next item.
- [ ] A test over the scripted model: the pass runs on the worker task, and the SDK call returns the output of that pass.
- [ ] The tests of ^8csj2hw, ^93kjn94 and ^ake8sax stay green. No assertion of them is weakened.
- [ ] Full `swift test` green, 0 new warnings. #generation-queue