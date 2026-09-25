---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cyv20qy3j473dkftsnzz1q
  text: 'Note from the design task ^jdp02p for step 6. In ^1psqdm9 the wait-cycle check is in the submit of the queue: a child `respond` then submits on the task of the tool, which carries the OPEN `ModelCallMark`. After this task, the pump of the child session submits on its own task, which inherits no task-local. So the check must move to the helper that waits for an answer: `respond(to:)` (and each stream helper) throws `GenerationQueueError.waitInsideOpenSubmission` at once when the calling task has an OPEN mark whose queue is the queue of the target session. This covers the own session and every other session over the same model. Keep a test for both cases. Design: `generation-queue.md` section 5.5, rule 2.'
  timestamp: 2026-09-25T18:56:57.879281+00:00
depends_on:
- 01M3CYJ4VS4VF5EEHA01PSQDM9
- 01M3CYJJGNHH04AREE9DPN2YTT
position_column: todo
position_ordinal: '9280'
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

- [ ] `turnLock` and every `AsyncSemaphore` in `Session/` are gone. No caller waits on a semaphore.
- [ ] A test: while a submission of a session runs, a second `respond(to:)` on that session waits on no lock. Its prompt waits in the outbox, goes into the next submission, and each caller gets the answer of the submission that carried its prompt.
- [ ] A test: mail that arrives while a submission runs goes into the prompt of the next submission, never into the running one. The next submission starts with no caller call.
- [ ] A test: a background body asks its own session for an answer and gets it, with no error and no hang.
- [ ] A test: an in-band tool that waits for an answer of its own session gets the wait-cycle error at once.
- [ ] A test: a cancel withdraws the waiting caller messages (their callers get `CancellationError`), stops the running submission, and keeps the waiting mail in the outbox.
- [ ] A test: a submission that fails after it took mail puts the mail back (no silent outbox loss), and a proactive compaction that throws records the failure and requeues its mail.
- [ ] The memory note `routed-session-cancellation-invariants` is updated for each invariant that changed (see `generation-queue.md` section 5.9).
- [ ] Full `swift test` green, 0 new warnings. The concurrency suites pass a parallel stress run with no crash that HEAD does not also show (^vg6bmq6). #generation-queue