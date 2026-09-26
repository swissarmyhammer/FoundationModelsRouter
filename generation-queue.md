# Plan: a generation queue for each model, and a prompt cache limited by bytes

This file is the design that the `generation-queue` and `prompt-cache` tasks on the Router board refer to. It records the decisions of 2026-09-24 and 2026-09-25. Two peer sessions wrote the first proposals: FoundationModelsAgents (the queue, and the prompt-cache plan) and mlx-swift-lm (the fork side of the prompt cache). This file keeps the parts that the Router tasks need, in their final form. Code references name symbols, not line numbers, because line numbers change.

**Read section 5 first.** On 2026-09-25 the user replaced the lock design with a work-queue design, and made one submission to Foundation (one whole SDK call) the item of the queue. Section 5 is the current design. Sections 1 to 4 are the history that led to it. Each decision of section 2 that section 5 replaces is marked **Superseded**.

## 1. The problem

This section describes the code before ^93kjn94. The turn-long gate is gone now.

There is one GPU, so only one generation runs at a time on one model. Before ^93kjn94, the Router enforced this with one `AsyncSemaphore(value: 1)` for each resident container (`ResidentModelGates.generation`). A turn took it in `RoutedSessionActor.beginTurn()` and kept it until `endTurn()`. The SDK runs the whole tool loop inside one `LanguageModelSession.respond`, so each tool body ran while the turn held the gate.

Results:

- Tool time holds the GPU, although the model does no work.
- A parent that waits in a tool for a child on the same model starves the child.
- Three workarounds grew around the lock: the `awaitingUser` release, `GenerationPermitLoan`, and the same-session re-entry refusal that reads the loan.

## 2. The model: queues, not locks (2026-09-24; partly superseded by section 5)

- **Inbound: a work queue for each model.** **Superseded (section 5.1):** the item was one generation pass (one call of `LanguageModelExecutor.respond`). Now the item is one submission to Foundation: one whole SDK call, with its passes and its tool bodies. A session that waits holds nothing, but a tool body holds the model, because it runs inside the submission.
- **Outbound: a mailbox for each session.** This part exists: `ToolContext.post`, `SessionMailbox`, `SessionOutbox`. Section 5.4 makes it the one input of a session: caller prompts and mail.

Decisions:

- **One queue for each pool entry, not one global queue** (user decision). Still valid. Two slots that resolve to the same pool entry share one queue. The pool key is `ResidencyKey` = (ref, role), and the role holds the context size. Thus the same ref with a different context is a different container with its own queue. Different models can generate at the same time, as now.
- **The seam is the executor call.** **Superseded as the queue seam (section 5.1).** Spike ^8nqkten proved: one executor call ends BEFORE the SDK starts the tool body of that call, on the respond path and the stream path, over the scripted model and over `MLXLanguageModel` (Qwen3-4B-4bit). Tests: `ExecutorPassBoundaryTests`, `ExecutorPassBoundaryIntegrationTests`. The proof stays true and the tests stay. It is now the reason that the stall watch can tell generation time from tool time inside one submission (section 5.6), and the reason that a per-pass queue was possible. The user chose the submission as the item instead.
- **The queued wrapper is one instance for each session.** Still valid as the per-session wrapper, with no queue in it (section 5.3): task ^1psqdm9 renames it `SessionLanguageModel`. The container makes one wrapper `LanguageModel` for each backend it vends (each session, each fork, each summarizer backend). All wrappers of one container share the container's queue. The executor cache key (`Executor.Configuration`) of the wrapper compares by the identity of the per-session wrapper state. It must not compare only by the queue and the inner configuration: the SDK caches executors by that key, and two sessions with equal keys would share one executor (and later one prompt-cache key). `RecordingLanguageModel` compares by state identity for the same reason.
- **The wrapper keeps a reference to the raw `MLXLanguageModel`.** `respondWithoutReasoning` casts `model as? MLXLanguageModel`, and `evict(container:)` needs the raw model.
- **Recording gets its own lock.** `RecordingLanguageModelState` now takes `generationGate` around its diff and around the inner executor call. When the wrapper does the GPU queue, Recording keeps only a lock for its own diff-and-record. The two changes ship together.
- **`turnLock` stays for the whole request.** **Superseded (section 5.4):** `turnLock` is an `AsyncSemaphore`, and the user said "not with a lock". One pump task for each session replaces it: the pump is the only code that submits for its session, and it submits the next item only after the result of the last one. Transcript reads use a settled copy (section 5.8).
- **The per-session wrapper is also the seam for per-pass session work:** the prompt-cache key (section 3), and the report to the session actor that a pass started and ended (the stall watch, ^ake8sax). Still valid. A task-local bound on the session actor does not reach the executor through `LanguageModelSession`, because the SDK can run the executor on another task.
- **The semaphore in `GenerationQueue`.** **Superseded (section 5.3):** `GenerationQueue` is an `AsyncSemaphore(value: 1)` that each caller waits on. The user counts that as a lock. One worker for each model replaces it.
- **A wait for a queue place is not a stall (^ake8sax).** **Partly superseded (section 5.6):** the rule stays (a wait for the model and a tool body are not a stall), but the wait is now the wait of a submission, and `passQueued`/`passStarted` become `submissionQueued`/`submissionStarted`. The text below is the design of ^ake8sax as it shipped. The session actor installs a `GenerationPassObserver` on the per-session wrapper state of each backend it runs through. The executor reports three points of each pass to it: the pass joins the queue (only when another pass holds the place), the pass takes the place, and the pass leaves the queue. The calls are synchronous and append phases under a lock; the session actor applies them in order. The stall watch counts only the time a pass holds its place, so a queue wait and a tool body give no `generationStalled`. `GenerationStall.timeInFlight` stays the whole model call, and `visibility` and `lastProgress` keep their meaning. The consumer sees a wait as `SessionEvent.passQueued`, then `SessionEvent.passStarted`. A backend with no executor seam reports no pass, and its whole call counts as before.

## 3. The prompt cache

The fork keeps one KV prompt cache for each session in `ExecutorPromptCacheStore.shared`. Now the key is (modelID, id of the first transcript entry), the store keeps at most `maximumRetainedSessions = 4` entries in memory, and an evicted entry is lost. With passes of many sessions interleaved, the round-robin removes a cache before its session comes back.

Decisions (user, 2026-09-24):

- **The limit is memory in bytes, not a number of sessions.** No fixed session count stays in the code.
- **An entry that does not fit in memory goes to disk and comes back.** The fork writes it in a folder for each process under the temporary directory, and deletes the folders of dead processes at start.
- **The Router sizes the byte budget** from the pool: the recommended working set minus the footprints of the resident entries (weights plus one KV estimate for each slot hold; many sessions share one hold). Resident prompt-cache memory is `memoryBytes + spillingBytes` (an entry that is being written to disk is still in memory).
- **Each session has its own cache key.** Still valid in the work-queue model (section 5.3): the SDK call of a submission runs on a worker task, and the SDK then calls the executor of the per-session wrapper, so the binding inside the executor `respond` is still on the task of the inner executor call. The per-session wrapper binds the fork's task-local `MLXLanguageModel.promptCacheScope` to `.session(<session ULID>)` inside its executor `respond`, on the same task as the inner executor call. A fork thus has its own key, and a compaction keeps the key. A summarizer backend binds `.uncached` and keeps nothing. Do not bind `.none`: the task-local has the type `PromptCacheScope?`, so `.none` is `Optional.none` (no scope, the first-entry-id rule), and the compiler gives no error.
- **`RoutedSession.close()` releases the session's key** with `releasePromptCache(sessionID:)`, before the early return of `close()` when there are no terminal events.
- **A restore failure gives a cold start**, never a failed request.
- **A cold cache after a process restart is acceptable** (user decision, 2026-09-24). The fork's spool is one temporary folder for each process, and the fork deletes the folders of dead processes at start. A session restored from its recording after a restart computes its cache again from the start. No fork task and no Router task keep the cache across a restart.

### Fork API (mlx-swift-lm board, 2026-09-24)

```swift
public enum PromptCacheScope: Sendable, Hashable { case session(String); case uncached }
@TaskLocal public static var promptCacheScope: PromptCacheScope?   // nil = first-entry-id rule
public static func configurePromptCache(memoryBudgetBytes: Int) async
public static func configurePromptCache(diskBudgetBytes: Int) async
public func releasePromptCache(sessionID: String) async            // memory + spilling + disk; no-op if unknown
public static var promptCacheUsage: (memoryBytes: Int, spillingBytes: Int, diskBytes: Int) { get async }
```

Fork defaults when the host sets nothing: memory = 25% of max(0, maxRecommendedWorkingSetSize - Memory.activeMemory) at first use; disk = 25% of the free space of the volume.

Fork tasks: ^375zmcs (byte count), ^ddjhenh (byte budget), ^jvag56k (restore into fresh caches), ^b28dxz2 (offset through the file), ^z6av3ep (file format), ^w0s77dt and ^fzvh9gx (disk spool), ^jar6qq9 (restore in the executor), ^2mk47nr (the task-local key; needs ^ddjhenh), ^6zkwn0q (rename `.none` to `.uncached`), ^zcys2qw (public budget API and release; needs the spool), ^mre55m3 (measure the spill cost and the `evalLock` hold time).

Risk: a spill write holds MLX's process-wide `evalLock` for the whole write, which stops the generation of every model. The fork has one serial writer, so two holds do not overlap. R1 reads the measurements below before it chooses the budget.

Measurements of ^mre55m3 (2026-09-24). A disk write and a read of a prompt cache cost much less than a prefill, on both models:

| Model | Context | Prefill s | File bytes | Write s | Read s | Longest `evalLock` hold s |
|---|---|---|---|---|---|---|
| Qwen3-4B-4bit | 4096 | 1.567 | 604 MB | 0.122 | 0.020 | 0.122 |
| Qwen3-4B-4bit | 32768 | 13.085 | 4.83 GB | 1.187 | 0.161 | 1.187 |
| Qwen3.8-27B-mxfp4 | 4096 | 5.025 | 422 MB | 0.052 | 0.016 | 0.052 |
| Qwen3.8-27B-mxfp4 | 32768 | 52.991 | 2.30 GB | 0.224 | 0.075 | 0.224 |

- After each restore, the next token is the same as the original, in all four cases.
- Limit: each read came immediately after its write, so the file was probably in the OS page cache. A read from a cold disk can be slower.
- Result for the Router: a 32k spill of a 4B model that has only attention layers holds `evalLock` for approximately 1.2 s. During that time, the evaluation of every other model stops.

## 4. Router tasks

| Task | What | Needs |
|---|---|---|
| ^8nqkten | Spike: the executor call ends before the tool body | — |
| ^8csj2hw | The queue at the executor seam, per-session wrapper, Recording lock | ^8nqkten |
| ^93kjn94 | No turn-long gate; a request that waits for the GPU can be cancelled | ^8csj2hw |
| ^44y6ba4 | Delete the permit loan and the human-wait release | ^93kjn94 |
| ^6wqketz | Each summarizer call on the queue of its own container | ^93kjn94, ^1psqdm9 |
| ^ake8sax | A queue wait is not a stall; tell the consumer about the wait | ^93kjn94 |
| R1 ^tv2yt7s | Size the prompt-cache byte budget from the pool | ^8nqkten, fork ^zcys2qw |
| R2 ^cc2tezn | A cache key for each session, and a release on close | ^8csj2hw, fork ^2mk47nr, ^zcys2qw |
| R3 ^ptev9yy | Summarizer calls keep no cache | ^6wqketz, R2, fork ^2mk47nr |
| ^njdp02p | Design: sessions as work queues (section 5) | ^44y6ba4 |
| ^a0ze9af | The generation queue runs on one worker task for each model, not on a semaphore | ^njdp02p |
| ^1psqdm9 | One submission to Foundation is the item of the generation queue | ^a0ze9af |
| ^dpn2ytt | Read and fork a session from its settled transcript, with no wait on `turnLock` | ^1psqdm9 |
| ^3qx0mpt | A per-session message queue and one pump task replace `turnLock` | ^1psqdm9, ^dpn2ytt |
| ^cbhpdjy | Public message API: `send`, `MessageID`, `cancel()` | ^3qx0mpt |
| ^x7cxsg3 | Submission and answer events; `SessionAnswer` replaces `TurnOutcome` | ^cbhpdjy |
| ^5d0qx1b | Limits for each answer; keep the stored key `recoveriesPerTurn` | ^3qx0mpt |
| ^f33q8gw | Rewritten: remove the last "turn" names (boundary tool, `awaitingUser`, tracing, docs) | ^x7cxsg3, ^5d0qx1b |
| ^d7d777f | Update the consumers | ^f33q8gw |

The board cannot link a task on the fork board. A Router task that needs a fork task carries the tag `needs-fork` until that fork task is merged on the fork's `stable` branch and the Router pin is bumped.

## 5. Sessions as work queues

Design task ^njdp02p, 2026-09-25. Code facts were read at commit ef2d2d8.

### 5.0 The decisions of the user

The user said, word for word:

- "i really really don't want a lock based design, i want a work queue".
- The "turn" concept is vague and problematic, "as opposed to a queue of requests to the Foundation level model to do generation or tool calling". A rename of "turn" to "request" is not the goal.
- "i want router to queue up 'going to the foundation model'".
- "not with a lock". An `AsyncSemaphore` that callers wait on is a lock. Thus `GenerationQueue` (^8csj2hw) and `turnLock` are both locks.
- "right -- going to Foundation to generate -- or call tools which might be multiple 'steps' inside Foundation -- that submission to Foundation needs to be queued".

The target model (accepted by the user):

- Each model has a work queue. One worker for each model runs the items in FIFO order. A submitter gets the result of its item. It does not hold or wait on a lock.
- A session is a transcript plus a queue of messages. A caller prompt is a message, the same as mail from a child run. Before each submission, the session puts the waiting messages into the context, and does a compaction when necessary.
- Events report each item and each final answer. `respond(prompt)` is only a helper: it sends a prompt and waits for the answer.
- No lock is visible in the API, the events or the errors.

### 5.1 The item: one submission to Foundation (question 1)

**Decision: the item of the queue of a model is one submission to Foundation.** A submission is one SDK call: one `LanguageModelSession.respond` or `streamResponse`, with all of its steps. The steps are the generation passes (executor calls) and the tool bodies that the SDK runs between them. The item is NOT one executor pass.

Evidence and reason:

- The user chose it (the last quote in 5.0).
- The SDK runs the whole tool loop inside one call. ^8nqkten proved that one executor call ends before the SDK starts the tool body of that call. So a tool body runs inside the SDK call, between two passes. A submission thus holds the worker of its model for all of its steps, tool bodies included.
- The per-pass item of ^8csj2hw was possible because of ^8nqkten. It let another session generate while a tool body ran. The user chose the simpler item instead. The cost is in 5.5: a tool must not wait inside a submission.
- Mail between two passes inside one submission is not needed, and no seam inside a submission is built. The candidate seams of the first version of this task (the tool-result append boundary, the executor wrapper) are not used for mail. `ToolResultAppendBoundary` stays for its current job: the compaction yield at a tool result (5.5).

How each input leads to the next submission:

| Input | What happens |
|---|---|
| A caller prompt | It waits in the message queue of the session. When no submission of the session runs, the pump takes it and submits. When a submission runs, it waits for the next cycle of the pump. |
| Mail (for example the terminal of a settled background run) | The same as a caller prompt. The pump starts a submission for mail with no caller call, as `dispatchNextPrompt()` does now for a settled run with `settledRunDeliveryPrompt`. |
| A tool result | It is a step inside the running submission. The SDK gives it to the next pass of the same submission. It never causes a submission of its own. |

The spike `Tests/FoundationModelsRouterTests/SubmissionQueueSpikeTests.swift` proves the chosen mechanism over the scripted model, with no production change. It has a test model of the worker (`SubmissionWorker`, an actor with a FIFO list). A parent session mounts a background tool. The tool submits a prompt to a child session on the same model and returns at once. Results:

1. The worker starts the submissions in the order parent, child, parent.
2. The first parent submission ends before the child submission starts (the passes are `a`, `a`, `b`).
3. The terminal of the background run is the answer of the child. It reaches the parent as mail (`SessionEvent.runSettled`).
4. The mail causes the next submission of the parent (the test acts as the pump: it submits `dispatchNextPrompt()`), and the prompt of that submission holds the answer of the child and `settledRunDeliveryPrompt`.

The same test with the tool mounted in-band (`ToolMount(mode: .runToCompletion)`) fails: the first parent submission never ends inside the bound, because the child submission waits behind it. This is the deadlock of 5.5, observed.

### 5.2 The form of a delivered message, and the prompt cache (question 2)

**Decision: the waiting messages become the `.prompt` entry of the next submission.** The mail comes first, as the preamble that `composedPrompt(pendingEvents:prompt:)` makes now (one line for each event, from `OperationEventSegment.renderedLine(for:)`). The caller prompts come after it, in FIFO order.

The other forms, and why they are not used:

- **A tool output.** A message in a tool output would need a seam inside a submission. 5.1 does not build one.
- **A system note (a change of the instructions).** The instructions are the head of the prompt. A change there changes the prefix, and the whole context must be computed again. The cost is the full prefill of the section 3 table: 13.1 s for Qwen3-4B-4bit at 32768 tokens, 53.0 s for Qwen3.8-27B-mxfp4 at 32768 tokens.
- **An edit of the transcript in the executor request.** `LanguageModelExecutorGenerationRequest.transcript` is a `var`, so the executor wrapper could add an entry for one pass. The SDK transcript would not hold it, the recording would not hold it, and the next pass would not have it. The prefix would change between passes.

The `.prompt` entry is added at the end of the transcript. The prefix does not change, so the KV prompt cache of the session stays valid. Only the new prompt is computed. With R2 ^cc2tezn the key of the cache is the session id, so a new SDK call on the same session finds its cache.

### 5.3 The worker of a model (the mechanism, and the SDK's own task)

**Decision: `GenerationQueue` becomes a work queue with one worker. It holds no semaphore.** Recommended form: an actor that holds a FIFO list of items, and one drain task. The drain task runs the items one at a time, and ends when the list is empty. The next submission starts it again. The spike's `SubmissionWorker` is this form.

- **Submit.** A submitter gives one closure: the whole submission. It waits for the result of its own item through a continuation. It never waits on a semaphore or a lock. While a submission runs, the actor is free, so another submitter can join the list.
- **The item runs the SDK's call, not a copy.** The session builds the submission closure. The closure calls `backend.respond(...)` (or the stream call), which is the SDK call itself. The worker runs that closure on its own task. The SDK then runs its passes and tool bodies below that call. So the worker runs the real call, with the real transcript, tools and channel.
- **Task-locals.** A task that the worker makes inherits no task-local of the submitter. The closure must bind every task-local that the call needs: `ModelCallMark`, `ToolResultAppendBoundary`, `ToolContext` (now bound in `runCancellableModelCall`). The prompt-cache scope of R2 ^cc2tezn stays inside the executor `respond` of the per-session wrapper, which the SDK calls below the submission. It needs no change.
- **Cancel of a waiting item.** The submitter awaits inside `withTaskCancellationHandler`. On cancel, the handler asks the actor to remove the item. When the item still waits, the actor removes it and resumes the submitter with `CancellationError`. The item never runs.
- **Cancel of a running item.** When the item runs, the actor cancels the task that runs it. The SDK call unwinds, and the tool bodies get the cancel, as now.
- **Exactly one resume.** The state of each item (waiting, running, done) changes only inside the actor. The continuation resumes exactly one time, also when a cancel and the start of the item race.
- **Why this is not a lock.** No caller waits for a permission. A caller waits for the result of its own work, which one worker makes. The worker is the only code that runs items of the model.
- **Feasibility.** `LanguageModelExecutorGenerationRequest` and `LanguageModelExecutorGenerationChannel` are `Sendable`, and `LanguageModelExecutor.respond` is `nonisolated(nonsending)` (FoundationModels swiftinterface, macOS 27 SDK). Nothing in the SDK ties a call to the task of its caller. The spike runs whole SDK calls on the task of its worker.
- **A backend with no queue.** A backend with no executor seam (the test stubs) has no queue. Its call runs directly, as now. A consumer stub container can own a `GenerationQueue` and submit each scripted call to it (the decision of ^8csj2hw step 4).
- **Order of the work.** ^a0ze9af changes the mechanism first and keeps the item as one pass, so the tests of ^8csj2hw, ^93kjn94 and ^ake8sax prove that the worker keeps the old behavior. ^1psqdm9 then changes the item to one submission.
- **A recording handle (added by ^1psqdm9).** `RoutedModel.makeLanguageModel()` gives a consumer a `RecordingLanguageModel` over `LoadedLLMContainer.languageModel`. The consumer drives that SDK session itself, so the Router never makes its SDK call and cannot submit it whole. Its wrapper is `SessionLanguageModel(wrapping:passQueue:)`: each pass of it is one item of the queue of the model. So a recording handle never generates at the same time as a routed submission. The wrapper of a backend has no pass queue.
- **Where the refusal of 5.5 rule 2 runs (^1psqdm9).** `GenerationQueue.submit` refuses a submission from a task with an open `ModelCallMark` on the same queue. `RoutedSessionActor.beginTurn()` runs the same check before it waits for `turnLock`, so an in-band wait for a busy session on the same model is refused too, and does not wait for a turn lock that the waiting submission holds. **Since ^3qx0mpt** `beginTurn()` and `turnLock` are gone: each helper that waits for an answer (`respond(to:)`, the two stream helpers, `dispatchNextPrompt()`, `compact(prompt:budget:)`) runs `RoutedSessionActor.refuseWaitInsideOpenSubmission()` on the task of its caller. It refuses an OPEN mark of the same session (also over a backend with no queue) and an OPEN mark on the queue of the model of the session. The pump task is detached, so it inherits no mark. **Since ^cbhpdjy** `dispatchNextPrompt()` is gone. `send(_:)` does not wait for an answer, thus it runs no refusal: a tool of a submission can send a message to its own session.

### 5.4 The per-session message queue: the SDK limit with no lock (question 5)

The SDK allows one call at a time on one `LanguageModelSession`. Evidence: `LanguageModelSession.Error.concurrentRequests` and `LanguageModelSession.isResponding` in the FoundationModels interface.

**Decision: one pump task for each session is the only code that submits for that session.** The pump submits the next item only after the result of the last one. So the session never has two SDK calls, and no caller waits on a lock.

- **The queue of messages.** `SessionOutbox` holds the waiting messages: the caller prompts (now the prompt queue of `enqueue(prompt:)`) and the mail (now the pending events). Each caller prompt gets a message id and a waiter for its answer.
- **A message that arrives while the session is idle.** No pump runs, so a pump starts. It takes the waiting messages and submits.
- **A message that arrives while a submission runs.** It waits in the outbox. It never goes into the running submission. When the submission ends, the pump takes every waiting message for the next submission.
- **Which messages share one submission.** Every waiting message with the same generation options. A message with its own options (a grammar, a schema, or a different token ceiling) goes alone, because the SDK fixes the options at the start of a call.
- **When the pump ends.** When no deliverable message waits. A progress report or an elicitation report alone does not start a submission; it waits for the next one (the rule of `deliverSettledRunsIfAny` now).
- **Answers.** The final answer of a chain of submissions (5.5) resumes the waiters of every caller message that the chain delivered. `respond(to:)` is a helper: send a message, then wait for its answer. `respond(to:)` no longer drains the run plane: a settled run is mail, and the pump delivers it. Task ^3qx0mpt builds the pump; task ^cbhpdjy gives it its public API.

### 5.5 Compaction, continuations, and tools (questions 3 and 4)

**Compaction happens between two submissions, at the pump.** Before each submission, the pump does the proactive check of `runTurnWork` now (measured tokens against `TokenBudget.triggerTokens`), and compacts first when necessary. Mail and compaction thus share one boundary: the start of a submission.

**A continuation is a new submission.** The session makes one more submission for the same answer in five cases: a compaction yield at a tool result (`noteToolResult(_:)` sets the yield and cancels the call), a ceiling stop over the trigger, an overflow retry, a rejected tool call, and a repetition recovery. Each continuation goes to the back of the queue of the model. The messages that wait at that time go into its prompt, after the continuation text (for example `compactionContinuationPrompt`). The chain of submissions from the first delivery to the final answer is one "answer". `compactionYieldsStopped`, the count of repetition recoveries and the one overflow retry reset for each answer, not for each submission (^5d0qx1b).

**Tool calls are steps of a submission, not items of the model queue (question 4).** The user named tool calls as work. In the chosen model, the SDK runs each tool body on its own task inside the submission, and the Router cannot move a tool body out of the SDK call without a stop of the call. So:

- A tool call is a step of its submission. The events of a tool step already exist: `toolCall`, `toolStatus`, and the open and close `toolInvocation` records.
- The time of a tool body counts in its submission. It holds the worker of the model for every other session on that model.

**A tool must not wait inside a submission.** A tool body that waits for an answer of a session on the same model can never end: the submission of that session waits behind the submission of the tool (the spike observes this). The rules:

1. A tool that starts other work that can take long (a child agent, a build, a wait for a person) is a background tool (`BackgroundTool`, `ToolMount(mode: .background)`). It returns at once with its pending envelope. The result comes back to the session as mail, and the mail causes the next submission.
2. The Router refuses at once the one wait that can never end: a submission to queue Q, or a wait for an answer on a session over Q, from a task inside an open submission on Q. `ModelCallMark` names the queue of its submission for this check. The error is `GenerationQueueError.waitInsideOpenSubmission(model:)` (^1psqdm9). A hang is worse than an error. This is not a lock error: it names a wait cycle. A background body has a closed mark (`ModelCallMark.withBackgroundRunMark`), so it is never refused.
3. A tool may wait for work on a DIFFERENT model. That work runs on the other worker. The wait still holds its own model for the whole time.
4. `ToolMount.timeout` still bounds a run-to-completion tool that makes no progress.
5. `BackgroundTool.inlineSettleGrace` is an in-band wait. It holds the model for its whole time. A run on the same model can never settle inside it. Keep it small, as its doc comment says now.
6. `awaitingUser(_:)` goes (^f33q8gw). A wait for a person inside a tool holds the model. The way to wait for a person is an elicitation from a background run (`SessionEvent.elicitationRequested`, `respond(elicitationId:response:)`).

Code and tests that assume an in-band wait, and what each becomes:

| Code or test (at ef2d2d8) | Becomes |
|---|---|
| `BackgroundToolRunner` | Stays. It is the way to do long work. Its closed-mark wrap stays required (5.9). |
| `RunToCompletionRunner` | Stays. Its tool body holds the model; its doc says so (^1psqdm9). |
| `ModelCallMark` | Stays. It also names the queue of its submission, for the refusal of rule 2. |
| `refuseReentryOntoThisSession`, `SessionReentryError.sameSessionTurnInFlight` | Replaced by the refusal of rule 2 (^1psqdm9, ^3qx0mpt). A background body may ask its own session for an answer. |
| `SessionReentryError.forkDuringSameSessionTurn`, `isInsideOwnTurnToolCall` | Gone: a fork and a read use the settled transcript (5.8, ^dpn2ytt). |
| `awaitingUser(_:)` | Gone (^f33q8gw). |
| `respond(to:)` run-plane drain | Gone: the pump delivers settled runs as mail (^3qx0mpt). |
| `GenerationQueueTurnTests.aToolBodyThatWaitsLetsAnotherSessionCompleteATurn` | Restated: the other session runs after the whole submission (^1psqdm9). |
| `GenerationQueueTurnTests.twoToolLoopsTakeAlternatePasses` | Restated: whole submissions in FIFO order, no alternation (^1psqdm9). |
| `GenerationQueueTurnTests.aParentWaitsInAToolBodyForAChildTurnOnTheSameModel` | Replaced by the refusal of rule 2; the background shape is the spike (^1psqdm9). |
| `GenerationQueueTurnTests.aBackgroundRunGeneratesOnTheSameModelAfterItsTurnEnded` | Stays: it already has the new shape. |
| `HumanWaitGateTests` | Restated or removed with `awaitingUser` (^1psqdm9, ^f33q8gw). |
| `NestedGenerationReentryTests` | Restated to the refusal of rule 2 and to forks with no refusal (^1psqdm9, ^dpn2ytt, ^3qx0mpt). |
| `QueuedPassStallWatchTests.aWaitForAQueuePlaceIsNotAStall` | Restated to a wait for the worker (^1psqdm9). |
| `SharedGenerationQueueContentionTests`, `ForkConcurrencyTests.generationQueueSerializesPassesAndIsFIFO`, `GenerationQueueTests` | Restated to submissions (^a0ze9af, ^1psqdm9). |

### 5.6 Events, outcome, cancel, and the stored key (question 6)

**What stays, what moves, and what goes, from the per-pass work:**

| Now | Becomes |
|---|---|
| `GenerationQueue` (a semaphore; one pass is one item) | A work queue with one worker; one submission is one item (^a0ze9af, ^1psqdm9). |
| `QueuedLanguageModel` (per-session wrapper that queues each pass) | `SessionLanguageModel`: the same per-session wrapper with no queue. It keeps the identity key of ^8csj2hw, the pass observer, and the R2 prompt-cache scope (^1psqdm9). |
| `SessionEvent.passQueued` / `.passStarted` | `.submissionQueued` (only when the submission must wait) / `.submissionStarted` (^1psqdm9). |
| The stall watch counts the time a pass holds its queue place | The stall watch counts the time inside a pass of the running submission. A wait for the worker and a tool body give no stall. `GenerationStall.timeInFlight` stays the whole model call (^1psqdm9). |
| `SessionEvent.generationCall(GenerationCallUsage)` | Stays: one report for each pass inside a submission. |

**The event set (^x7cxsg3):**

- Of the item: `submissionQueued(SubmissionID)`, `submissionStarted(SubmissionStart)` (the id, the delivered `MessageID`s, the cause: caller message, mail or continuation), `submissionEnded(SubmissionEnd)` (the id, the `TokenUsage` of that SDK call, the `FinishReason`). `submissionEnded` replaces `turnEnded`, which already came one time for each SDK call.
- Of the answer: `answered(SessionAnswer)` one time for each final answer; `answerFailed(AnswerFailure)` when the chain ends with no answer (cancelled, or an error).
- Of the steps: `toolCall`, `toolStatus`, `toolInvocation`, `toolCallReport`, `textDelta`, `textReset`, `reasoningDelta`, `generationCall`, `generationStalled`, `repetitionStopped`, `entryRecorded` stay.
- Of the session: `compaction`, `runSettled`, `elicitationRequested`, `discoveryPrimingFailed` stay.
- `textDelta` and `textReset` also travel on `streamSessionEvents()`, because no caller owns a submission that mail started.

**The replacements:**

| Now | Becomes | Task |
|---|---|---|
| `TurnOutcome` | `SessionAnswer` (reply, answered `MessageID`s, summed usage, compactions, tool calls, tool invocation records) | ^x7cxsg3 |
| `TurnID`, `TurnStart` | `SubmissionID`, `SubmissionStart` | ^x7cxsg3 |
| `PromptID` | `MessageID` | ^cbhpdjy |
| `cancelCurrentTurn()`, `TurnCancellationResult` | `cancel()`, `CancellationResult` (`.requested`, `.nothingToCancel`) | ^cbhpdjy |
| `cancel(id:)`, `cancelPrompt(id:)`, `PromptCancellationResult` | `cancel(message:)`, `MessageCancellationResult` (`.withdrawn`, `.cancelledInSubmission`, `.alreadyAnswered`) | ^cbhpdjy |
| `SessionProjection.currentTurn` | `currentSubmission: SubmissionStart?`, and the waiting `MessageID`s | ^x7cxsg3 |
| `TurnBoundaryTool.turnWillBegin()` | `SubmissionBoundaryTool.submissionWillBegin()`, called one time before each submission of the pump | ^f33q8gw |
| `awaitingUser(_:)` | Gone (5.5 rule 6) | ^f33q8gw |
| Tracing span `turn`, attributes `turn.id`, `turn.entry_point` | Span `submission`, attributes `submission.id`, `submission.cause` | ^x7cxsg3 |
| `RepetitionDetection.recoveriesPerTurn` | `recoveriesPerAnswer` in Swift. The key on disk stays `recoveriesPerTurn` (`CodingKeys`), with no `schemaVersion` bump. Old recordings load. | ^5d0qx1b |
| `TranscriptEvent.isFailedTurnClose` | `isFailedAnswerClose` in Swift, with no change on disk | ^5d0qx1b |

**Cancel.** `cancel()` stops the running submission of the session (the worker cancels its task), removes the waiting submission of the session from the model queue, and withdraws the waiting caller messages (their waiters get `CancellationError`). Mail is not withdrawn: it stays in the outbox for a later submission, because a run terminal must not be lost (5.9).

**The stored key.** `session.json` holds `configuration.repetitionDetection.recoveriesPerTurn` (for example the untracked fixture `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/session.json`). The key stays on disk, and ^5d0qx1b adds a load test over such a fixture.

### 5.7 Long tools and fairness

- A submission holds its model from its first pass to its final answer, tool bodies included. A slow in-band tool delays every other session on that model. The mitigations are the rules of 5.5: long work is a background tool; a same-model wait is refused at once; `ToolMount.timeout` bounds a tool with no progress.
- FIFO order is kept for submissions. A continuation goes to the back of the queue, so one session with a long chain of continuations does not starve the others.
- The events make the wait visible: `submissionQueued` and `submissionStarted` on each session, and the tool invocation records with their times.

### 5.8 Reads and forks with no lock

A fork and a transcript read wait on `turnLock` now, and a fork from a tool of the same session throws `forkDuringSameSessionTurn`. In the new model:

- The session actor keeps a settled copy of the transcript. It updates the copy at the end of each submission and at each tool-result boundary (where `noteToolResult(_:)` already reads `backend.transcriptEntries()`).
- `transcript` returns the settled copy at once, from any task.
- `fork(workingDirectory:)` seeds the child from the settled copy at once. When the copy ends in tool calls with no output, the fork removes those calls, with the rule of `InFlightTranscript.removingUnansweredCalls`.
- A read never copies the live backend transcript while the SDK changes it on its own task (the race of the memory note `stub-backend-producer-race`).

Task: ^dpn2ytt.

### 5.9 The cancellation invariants (question 8)

Each item of the memory note `routed-session-cancellation-invariants`, checked against the new model:

| Invariant | Verdict | Reason |
|---|---|---|
| Gone since ^93kjn94: no turn-long model lock; each pass takes the queue with a cancellable wait | **Replace** | The rule "no session-wide model lock" stays and gets stronger: no lock at all. The cancellable wait becomes the removal of a waiting item from the worker (5.3). |
| Gone since ^44y6ba4: `ModelCallMark`; the `withBackgroundRunMark` wrap is required | **Keep** | The mark now names the queue of its submission, for the refusal of 5.5 rule 2. The wrap stays required, for the opposite reason from now: without it, a background body inherits the OPEN mark and a legal wait of the background body on the same model is refused. |
| Cancel decisions key on the `isTurnCancelled` predicate, never on the type of `CancellationError`; `cancelRequestedTurnId` has one read site | **Keep, renamed** | A backend can still throw `CancellationError` from its own internals. The predicate keys on the id of the running submission (or answer), with one read site. |
| `abandonFoldIfCancelled` stays non-`async` | **Keep** | The compaction fold is unchanged; it only moves to the pump. |
| `runTurn` brackets the proactive fold and calls `recordFailedTurn(...)` before a rethrow | **Keep, extended** | The pump drains mail before the proactive fold, so a fold that throws must still record the failure and requeue the mail. A submission that fails after it took mail must also requeue it (attach or requeue). |
| `try Task.checkCancellation()` after the stream loop | **Keep** | The SDK stream still ends (and does not throw) when its consumer is cancelled. |
| `AsyncSemaphore.wait()` is non-throwing so that a cancel leaves `turnLock` balanced; the queue uses `waitUnlessCancelled()` | **Gone** | No semaphore is left in the session or the queue. Its replacement is the exactly-one-resume rule of the worker (5.3), with its own race test (^a0ze9af). `AsyncSemaphore` may stay for tests and for other code. |
| The SDK crash `_ContiguousArrayStorage deallocated with non-zero retain count 2` (^vg6bmq6) | **Keep** | It is in FoundationModels frames and exists at HEAD. A stress run of the new code must compare with HEAD before it blames the change. |
| Tests: never a bare `await session.respond(...)` after a cancel; use `awaitCancelledUnwind` / `followUpTurnCompletes` | **Keep** | A stranded waiter still hangs the suite. The helpers are renamed with the "turn" names (^f33q8gw). |

The memory note `stub-backend-producer-race` stays valid: a stream producer can still outlive a cancelled submission.

### 5.10 The consumers (question 7)

The counts are from `rg` over each consumer's sources on 2026-09-25.

| Consumer | Uses now | Must change |
|---|---|---|
| FoundationModelsMultitool | `turnWillBegin` 27, `TurnBoundaryTool` 2, `turnEnded` 3, `turnStarted` 2, `cancelCurrentTurn` 1, `dispatchNextPrompt` 1 | `SubmissionBoundaryTool.submissionWillBegin()`; the submission events; `cancel()`; remove the `dispatchNextPrompt()` driver. `MultiTool.turnWillBegin()` applies a staged registry; `submissionWillBegin()` does the same job at the same place. |
| AgentViewKit | `cancelCurrentTurn` 11, `turnEnded` 10, `turnStarted` 6, `TurnStart` 1, `TurnID` 1 | `cancel()`; the submission and answer events; `SubmissionStart`, `SubmissionID`; a view of "the turn in flight" shows `currentSubmission` and the waiting messages. |
| FoundationModelsExtras | `TurnOutcome` 1 | `SessionAnswer`. |
| FoundationModelsAgents | `dispatchNextPrompt` 12, `cancelCurrentTurn` 1 | Remove the external driver (the pump delivers messages and settled runs); `cancel()`; the agent tool must start a child as a background run and return at once. |
| FoundationModelsACPAgent (not edited by the Router; its own card ^tz867gz) | `turnEnded` 26, `awaitingUser` 10, `turnStarted` 3, `cancelCurrentTurn` 3, `turnWillBegin` 2, `generationCall` 2, `passQueued`/`passStarted` (card ^rfn4m87) | The names above; `awaitingUser` is gone, and a permission wait inside an in-band tool now holds the model for every session on it; `submissionQueued`/`submissionStarted`; `generationCall` stays. |

**The "end your turn to wait" text of FoundationModelsAgents.** The phrase is not in its sources at its HEAD (`rg`). The nearest text is `AgentsToolText`: "Its final message comes to you when it finishes." In the chosen model, mail goes into the context only between two submissions. A model that wants the result of a child must still end its submission; the result then comes as a new message and causes the next submission by itself. So the instruction to end the answer and wait stays true. What changes: no external driver is needed to deliver the result, and an in-band wait for the child is refused at once. Task ^d7d777f updates the consumers.

### 5.11 The tasks, in order

| Order | Task | What |
|---|---|---|
| 1 | ^a0ze9af | The generation queue runs on one worker task, not on a semaphore (item still one pass). |
| 2 | ^1psqdm9 | One submission to Foundation is the item; `SessionLanguageModel`; submission events; the refusal of a same-model wait inside a submission. |
| 3 | ^dpn2ytt | Reads and forks from the settled transcript, with no wait on `turnLock`. |
| 4 | ^3qx0mpt | The per-session message queue and one pump replace `turnLock`. |
| 5 | ^cbhpdjy | Public message API: `send`, `MessageID`, `cancel()`, `cancel(message:)`. |
| 6 | ^x7cxsg3 | Submission and answer events; `SessionAnswer`; `currentSubmission`; the tracing span. |
| 7 | ^5d0qx1b | Limits for each answer; the stored key `recoveriesPerTurn` stays on disk. |
| 8 | ^f33q8gw | Rewritten: the boundary tool, `awaitingUser`, the last "turn" names and docs. |
| 9 | ^d7d777f | The consumers. |

The existing tasks: ^6wqketz now waits for ^1psqdm9 (a summarizer call is one submission on the queue of its own container). R2 ^cc2tezn and R3 ^ptev9yy keep their seam: the executor `respond` of the per-session wrapper. Each of them has a comment that says what changes.
