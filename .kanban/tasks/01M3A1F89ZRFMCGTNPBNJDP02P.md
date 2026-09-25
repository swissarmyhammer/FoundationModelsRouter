---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cxm7w5k96bcg320cn2a0hn
  text: |-
    2026-09-25, from the user: "i want router to queue up 'going to the foundation model'". The queue item is each time the Router goes to the Foundation model. The design must state exactly which call that is, with evidence:
    - One `LanguageModelSession.respond` (the SDK call) runs the whole tool loop, tool bodies included. If the item is the whole SDK call, a slow tool body holds the queue place of the model again. That was the original problem (generation-queue.md section 1).
    - One executor call (one generation pass) ends before the SDK runs the tool body of that pass (^8nqkten). An item for each pass does not hold the place during a tool body. This is the seam that ^8csj2hw uses now.
    Recommend one and write why. Show how a caller prompt, mail, and a tool result each lead to the next trip to the model.
  timestamp: 2026-09-25T18:35:45.925361+00:00
- actor: claude-code
  id: 01m3cxmpc2k990s8r58zewxmpa
  text: |-
    2026-09-25, from the user: "not with a lock". This applies to the code that exists now, not only to the "turn":
    - `GenerationQueue` (^8csj2hw, `Concurrency/GenerationQueue.swift`) is an `AsyncSemaphore` with one place. Each pass waits on the semaphore. That is a lock with a queue name.
    - `turnLock` is also an `AsyncSemaphore`.
    The design must replace both with a real work queue: a session submits a work item (one trip to the Foundation model) to the queue of the model, and one worker for each model takes the items in order (FIFO) and runs them. A submitter gets the result of its item; it does not hold or wait on a lock. State how cancel removes a waiting item, how the worker runs an item that the SDK started on its own task (the executor call arrives from the SDK; the item must run that call, not a copy), and how the per-session limit of the SDK (one `LanguageModelSession.respond` at a time) is a per-session queue of messages, not a lock. Keep the proofs of ^8nqkten and the tests of ^8csj2hw, ^93kjn94 and ^ake8sax as behavior that the new design must keep.
  timestamp: 2026-09-25T18:36:00.770764+00:00
depends_on:
- 01M39ZP766H4S63AR4R44Y6BA4
position_column: todo
position_ordinal: '8780'
title: 'Design: a work-queue session model with no locks and no "turn"'
---
## Why

The user decided on 2026-09-25: "i really really don't want a lock based design, i want a work queue". The "turn" concept is vague and must go, "as opposed to a queue of requests to the Foundation level model to do generation or tool calling". A rename of "turn" to "request" is NOT the goal.

What the "turn" does now (at commit 50a629e):

- **Lock.** A session holds `turnLock` from a caller's `respond`/`stream` to the final answer. A second call waits. A tool that calls its own session gets `sameSessionTurnInFlight` or `forkDuringSameSessionTurn`, because it would wait for itself.
- **Mail.** The outbox and the mailbox go into the prompt only when a new call starts (`finishTurnAndRequeueIfUnattached` in `Session/RoutedSessionActorRecording.swift`, `dispatchNextPrompt()`). A model in a long tool loop does not see a finished child run until the call ends. This is why agents need the "end your turn to wait" text.
- **Compaction.** The check is at the start of a call, plus at a tool result or a ceiling stop (`Session/RoutedSessionActorCompactionYield.swift`). `compactionYieldsStopped` resets one time for each call.
- **Events and cancel.** `turnStarted` is sent one time for each call, but `turnEnded` one time for each SDK attempt, and no event marks the end of a call. `cancelCurrentTurn()` cancels the whole call. `TurnOutcome`, `TurnID`, `SessionProjection.currentTurn`, `TurnBoundaryTool.turnWillBegin()`.

## Target model (accepted by the user)

- Each model has a work queue. An item is one piece of work: a generation, or a tool call.
- A session is a transcript plus a mailbox. A caller prompt is a message in the mailbox, the same as mail from a child run. Before each generation, the session puts the waiting messages into the context, and does compaction if necessary.
- Events report each item (queued, started, ended) and each final answer. `respond(prompt)` is only a helper: it sends a prompt and waits for the next final answer.
- No lock is visible in the API, the events or the errors. A second prompt, or a call from a tool to its own session, is a message that the model reads at its next generation. The self-call errors go away.
- Cancel stops the current item of the session and the items of the session that wait in a queue.

## Hard limit

The Apple SDK runs the whole tool loop inside one `LanguageModelSession.respond`, and one SDK session cannot run two such calls at the same time. The Router must handle this privately, as a queue (for example a serial per-session inbox), not as a public lock.

## Questions to answer (output: a written design, a spike, and tasks)

1. **Mail between passes.** Can the Router add a message to the context between two generation passes inside one SDK call? Candidate seams: the tool-result append boundary (`ToolResultAppendBoundary`), the per-session queued executor wrapper of ^8csj2hw (it sees each pass), or stop-and-continue as the compaction yield does now. Give evidence.
2. **Form of a delivered message:** a tool output, an extra user entry, or a system note. What does each form do to the KV prompt cache (a prefix change forces a full prefill; R1 cost table in `generation-queue.md` section 3)?
3. **Compaction** on the same seam, so there is one boundary for mail and compaction.
4. **Tool calls as queue items.** The user named tool calls as queue items. A tool body must not hold the GPU place (proved in ^8nqkten; it is the reason for the per-pass queue). Decide how a tool call is a work item without blocking generation of other sessions (for example a separate tool queue, or a tool item that holds no GPU place).
5. **The private SDK limit.** How the per-session queue stops two SDK calls on one session without a lock in the API. What happens when a message arrives while an SDK call runs, and when it arrives while the session is idle.
6. **Events, cancel and outcome.** The new event set (keep `passQueued`/`passStarted` from ^ake8sax), the replacement for `TurnOutcome`, `TurnID`, `cancelCurrentTurn()`, `SessionProjection.currentTurn`, `TurnBoundaryTool`, `awaitingUser`, and the stored key `recoveriesPerTurn` in `session.json` (old recordings must still load).
7. **Consumers.** FoundationModelsMultitool, AgentViewKit, FoundationModelsAgents and FoundationModelsACPAgent use this package from its `main` branch. List what each must change. Does mail at each pass remove the "end your turn to wait" text in FoundationModelsAgents?
8. **Invariants.** Check each item in the memory note `routed-session-cancellation-invariants.md` against the new model: keep, replace, or no longer needed, with the reason.

## Rules

- Do not ask the user about names or details. Decide them and write the reason. A true scope or design conflict goes back to the main session as `stuck`, with full context.
- Write in ASD-STE100 Simplified Technical English.

## Acceptance Criteria

- [ ] `generation-queue.md` has a new section, "Sessions as work queues", that answers questions 1-8 with evidence (file and symbol names; line numbers only with the commit they were read at).
- [ ] A spike test proves that the chosen seam can add one message between two generation passes of one SDK call (or proves that it cannot, and the design uses stop-and-continue).
- [ ] Implementation tasks are on the board in a dependency order, each small enough for one review. They replace ^f33q8gw (the rename), which then depends on them or is deleted.
- [ ] No implementation code changes in this task, except the spike test. #generation-queue #design