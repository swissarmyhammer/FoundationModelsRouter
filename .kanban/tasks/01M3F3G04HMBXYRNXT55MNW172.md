---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
title: Install the caller cancel handler before a message reaches the outbox
---
## What

Found during ^cx1type. `sendAndAwaitAnswer` (RoutedSessionActorGeneration.swift) calls `await enqueue(message)` and only after that enters `awaitAnswer(of:)`, which installs the cancel handler that sets the mark (`PumpAnswer.requestCancel()`).

`enqueue` suspends on `outbox.add(message:)`. When the pump already runs, it can take the message from the outbox and start its answer before the caller task gets the session actor back and installs the handler. A `Task.cancel()` of the caller in that window sets only `Task.isCancelled` of the caller. The mark comes later, when the handler is installed. After ^cx1type, `isWorkCancelled` reads the mark, so the answer stops at its next model call after the handler runs. The pump can get ahead of the caller only when the actor runs its jobs before the caller's job, for example when the caller has a lower priority than the pump.

## Why it is separate

No test can force this order: the caller and the pump both wait for the same actor, and the order of their jobs is up to the executor. ^cx1type needed a test that forces the order, so it did not change this.

## Proposal

Put `enqueue` inside the `withTaskCancellationHandler` operation, so the mark is set synchronously for any cancel after the message exists. Then handle a mark that is set before `openMessages` has the message: after `enqueue`, if the mark is set, call `cancel(message:)`, so the message is withdrawn at once and does not wait for the pump to drop it.

## Acceptance

- [ ] Decide if the change is worth it without a forced-order test, and write the decision here.
- [ ] If yes: the change, and a test for the pre-registration cancel (the caller gets `CancellationError` at once and the model does not run). #test-flake