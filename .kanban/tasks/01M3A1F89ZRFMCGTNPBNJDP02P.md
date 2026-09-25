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
- actor: claude-code
  id: 01m3cyfeqm4jn6vq31dk6mvvdy
  text: |-
    2026-09-25, new direction from the user, word for word: "right -- going to Foundation to generate -- or call tools which might be multiple 'steps' inside Foundation -- that submission to Foundation needs to be queued".

    Decision that follows: the queue item is ONE SUBMISSION TO FOUNDATION: one SDK call (`LanguageModelSession.respond` / `streamResponse`), with all of its steps (generation passes and tool bodies). It is NOT one executor pass. Mail and compaction go between two submissions. No seam inside a submission is designed or built.

    Research done (at commit ef2d2d8):
    - `GenerationQueue` (Concurrency/GenerationQueue.swift) is `AsyncSemaphore(value: 1)`; `QueuedLanguageModel.Executor.respond` waits on it for each pass. `turnLock` is an `AsyncSemaphore` taken in `beginTurn()` (Session/RoutedSessionActorTurnGating.swift). Both are locks in the sense of the user.
    - The SDK has `LanguageModelSession.Error.concurrentRequests` and `isResponding` (FoundationModels swiftinterface, macOS 27 SDK): the one-call-at-a-time limit for each SDK session is real.
    - `LanguageModelExecutorGenerationRequest` and `LanguageModelExecutorGenerationChannel` are `Sendable`, and `LanguageModelExecutor.respond` is `nonisolated(nonsending)`. No SDK fact stops a worker task from running a whole SDK call.
    - Mail between submissions exists now: `dispatchNextPrompt()` with no queued prompt and a settled run runs a delivery turn with `settledRunDeliveryPrompt`, and `OperationEventSegment.renderedLine(for:)` puts the run's `detail` in the prompt.
    - In-band waits in the code now: `RunToCompletionRunner` (a tool runs to its end inside the call), `BackgroundTool.inlineSettleGrace` (a short wait inside the call), `awaitingUser(_:)` (a pass-through now), `respond(to:)`'s run-plane drain (a wait outside the SDK call, but inside `turnLock`).
    - Tests that assume a tool can wait in-band for a same-model session: `GenerationQueueTurnTests.aToolBodyThatWaitsLetsAnotherSessionCompleteATurn`, `.twoToolLoopsTakeAlternatePasses`, `.aParentWaitsInAToolBodyForAChildTurnOnTheSameModel`, `HumanWaitGateTests`, the refusal tests of `NestedGenerationReentryTests`, `QueuedPassStallWatchTests.aWaitForAQueuePlaceIsNotAStall`.
    - The phrase "end your turn to wait" is not in the FoundationModelsAgents sources at its HEAD (`rg` found nothing). The nearest text is `AgentsToolText` "Its final message comes to you when it finishes."
    - Found and corrected in a test helper: `PassObservingModel.callTool` wrote its tool arguments as `{"value":"<prompt>-<n>"}` with no JSON escape. A prompt with a quote or a line break (a delivery prompt) gave invalid JSON. It now uses `GeneratedContent(properties:).jsonString`. This is test support code, not production code.
    - The build shows `warning: 'foundationmodelsrouter': found 2 file(s) which are unhandled`. The cause is the untracked `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/` directory (2 files). This task does not touch that directory.
  timestamp: 2026-09-25T18:50:37.684939+00:00
- actor: claude-code
  id: 01m3czphj2n3kx2a7xv5asgemv
  text: |-
    ### implement — changed
    - evidence: 3 files (plus kanban). `generation-queue.md`: new section 5 "Sessions as work queues" (5.0 to 5.11 answer questions 1-8 with evidence at ef2d2d8); sections 1-4 updated, with each replaced decision marked **Superseded** (per-pass item, executor seam as queue seam, `turnLock` for the whole request, the semaphore in `GenerationQueue`, the queue-wait stall rule); the task table of section 4 lists the new tasks. `Tests/FoundationModelsRouterTests/SubmissionQueueSpikeTests.swift` (new spike, 1 test). `Tests/FoundationModelsRouterTests/Helpers/PassObservingModel.swift` (test helper: tool arguments are now JSON-encoded with `GeneratedContent(properties:).jsonString`; a delivery prompt with quotes or line breaks gave invalid JSON before).
    - spike: RED first with the tool mounted in-band (`ToolMount(mode: .runToCompletion)`): "the first submission of the parent ... was never observed inside the bound" (the same-model deadlock, observed). GREEN with the background tool: `swift test --skip-build --filter SubmissionQueueSpikeTests` -> "Test run with 1 test in 1 suite passed". 50 repetitions through `swiftpm-testing-helper`: passed. GenerationQueueTurnTests, QueuedPassStallWatchTests and GenerationQueueTests (users of PassObservingModel) 5 repetitions each: passed.
    - full suite: `swift test --skip-build` -> "Test run with 1407 tests in 162 suites passed ... with 2 known issues", plus 3 and 19 tests: 1429 = 1428 + the spike. The machine had a load average of 27-31 (another application used about 10 CPU cores). Three other full runs under that load failed on timing tests only: mass 60 s time-limit failures in the first run, 2 `QueuedPassStallWatchTests` timing expectations in one run (5 of 5 isolated runs pass), and the known `HumanWaitGateTests` `SignalNeverArrived` flake (^1qpmghh) in one run.
    - warnings: none from this change. The build shows "found 2 file(s) which are unhandled": the untracked directory `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/` causes it (not touched; ^5d0qx1b declares it as a resource). Also the known mlx "missing creator" line.
    - new tasks, in order: ^a0ze9af (worker, no semaphore), ^1psqdm9 (one submission is the item), ^dpn2ytt (settled transcript for reads and forks), ^3qx0mpt (pump replaces `turnLock`), ^cbhpdjy (message API), ^x7cxsg3 (events, `SessionAnswer`), ^5d0qx1b (limits for each answer, stored key), ^d7d777f (consumers). ^f33q8gw is REWRITTEN (not deleted) to the last "turn" cleanup, and depends on ^x7cxsg3 and ^5d0qx1b. ^a0ze9af depends on this task. ^6wqketz now also depends on ^1psqdm9. Comments with what changes are on ^cc2tezn (R2), ^ptev9yy (R3), ^6wqketz, ^f33q8gw and ^3qx0mpt.
    - decisions made without the user (per the rules), with the reason in section 5: the refusal `GenerationQueueError.waitInsideOpenSubmission(model:)` for an in-band wait on the same model (a hang is worse; it names a wait cycle, not a lock); a message with its own generation options goes alone in its submission; `submissionEnded` replaces `turnEnded` one for one; the on-disk key `recoveriesPerTurn` stays.
    - memory: `work-queue-not-locks.md` names the design section, the tasks and the spike.
    - no true conflict with the SDK: request and channel are `Sendable`, and the spike runs whole SDK calls on a worker task.
    - next: /review
  timestamp: 2026-09-25T19:11:58.530783+00:00
depends_on:
- 01M39ZP766H4S63AR4R44Y6BA4
position_column: doing
position_ordinal: '80'
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

Changed by the user on 2026-09-25 (see the comments): "right -- going to Foundation to generate -- or call tools which might be multiple 'steps' inside Foundation -- that submission to Foundation needs to be queued". The item is one submission to Foundation (one whole SDK call). Mail and compaction go between two submissions. The spike proves that mechanism, not a seam between two passes.

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

- [x] `generation-queue.md` has a new section, "Sessions as work queues", that answers questions 1-8 with evidence (file and symbol names; line numbers only with the commit they were read at).
- [x] A spike test proves that the chosen seam can add one message between two generation passes of one SDK call (or proves that it cannot, and the design uses stop-and-continue). Changed by the user's direction of 2026-09-25: the spike `SubmissionQueueSpikeTests` proves the chosen mechanism instead (a result delivered as mail causes the next submission, with the message in its prompt; an in-band wait on the same model never ends).
- [x] Implementation tasks are on the board in a dependency order, each small enough for one review. They replace ^f33q8gw (the rename), which then depends on them or is deleted.
- [x] No implementation code changes in this task, except the spike test. #generation-queue #design