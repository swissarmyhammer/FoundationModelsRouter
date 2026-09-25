# Plan: a generation queue for each model, and a prompt cache limited by bytes

This file is the design that the `generation-queue` and `prompt-cache` tasks on the Router board refer to. It records the decisions of 2026-09-24. Two peer sessions wrote the first proposals: FoundationModelsAgents (the queue, and the prompt-cache plan) and mlx-swift-lm (the fork side of the prompt cache). This file keeps the parts that the Router tasks need, in their final form. Code references name symbols, not line numbers, because line numbers change.

## 1. The problem

There is one GPU, so only one generation runs at a time on one model. Now the Router enforces this with one `AsyncSemaphore(value: 1)` for each resident container (`ResidentModelGates.generation`). A turn takes it in `RoutedSessionActor.beginTurn()` and keeps it until `endTurn()`. The SDK runs the whole tool loop inside one `LanguageModelSession.respond`, so each tool body runs while the turn holds the gate.

Results:

- Tool time holds the GPU, although the model does no work.
- A parent that waits in a tool for a child on the same model starves the child.
- Three workarounds grew around the lock: the `awaitingUser` release, `GenerationPermitLoan`, and the same-session re-entry refusal that reads the loan.

## 2. The model: queues, not locks

- **Inbound: a work queue for each model.** One generation pass (one call of `LanguageModelExecutor.respond`) is one item. A session that runs a tool or waits holds nothing.
- **Outbound: a mailbox for each session.** This part exists: `ToolContext.post`, `SessionMailbox`, `SessionOutbox`.

Decisions:

- **One queue for each pool entry, not one global queue** (user decision). Two slots that resolve to the same pool entry share one queue. The pool key is `ResidencyKey` = (ref, role), and the role holds the context size. Thus the same ref with a different context is a different container with its own queue. Different models can generate at the same time, as now.
- **The seam is the executor call.** Spike ^8nqkten proved it: one executor call ends BEFORE the SDK starts the tool body of that call, on the respond path and the stream path, over the scripted model and over `MLXLanguageModel` (Qwen3-4B-4bit). A queue place held for one executor call is thus not held across a tool body. Tests: `ExecutorPassBoundaryTests`, `ExecutorPassBoundaryIntegrationTests`.
- **The queued wrapper is one instance for each session.** The container makes one wrapper `LanguageModel` for each backend it vends (each session, each fork, each summarizer backend). All wrappers of one container share the container's queue. The executor cache key (`Executor.Configuration`) of the wrapper compares by the identity of the per-session wrapper state. It must not compare only by the queue and the inner configuration: the SDK caches executors by that key, and two sessions with equal keys would share one executor (and later one prompt-cache key). `RecordingLanguageModel` compares by state identity for the same reason.
- **The wrapper keeps a reference to the raw `MLXLanguageModel`.** `respondWithoutReasoning` casts `model as? MLXLanguageModel`, and `evict(container:)` needs the raw model.
- **Recording gets its own lock.** `RecordingLanguageModelState` now takes `generationGate` around its diff and around the inner executor call. When the wrapper does the GPU queue, Recording keeps only a lock for its own diff-and-record. The two changes ship together.
- **`turnLock` stays for the whole request.** It is the correctness gate: one request in flight for each session, and safe transcript reads.
- **The per-session wrapper is also the seam for per-pass session work:** the prompt-cache key (section 3), and the report to the session actor that a pass took its queue place (the stall watch, ^ake8sax). A task-local bound on the session actor does not reach the executor through `LanguageModelSession`, because the SDK can run the executor on another task.
- **A wait for a queue place is not a stall (^ake8sax).** The session actor installs a `GenerationPassObserver` on the per-session wrapper state of each backend it runs through. The executor reports three points of each pass to it: the pass joins the queue (only when another pass holds the place), the pass takes the place, and the pass leaves the queue. The calls are synchronous and append phases under a lock; the session actor applies them in order. The stall watch counts only the time a pass holds its place, so a queue wait and a tool body give no `generationStalled`. `GenerationStall.timeInFlight` stays the whole model call, and `visibility` and `lastProgress` keep their meaning. The consumer sees a wait as `SessionEvent.passQueued`, then `SessionEvent.passStarted`. A backend with no executor seam reports no pass, and its whole call counts as before.

## 3. The prompt cache

The fork keeps one KV prompt cache for each session in `ExecutorPromptCacheStore.shared`. Now the key is (modelID, id of the first transcript entry), the store keeps at most `maximumRetainedSessions = 4` entries in memory, and an evicted entry is lost. With passes of many sessions interleaved, the round-robin removes a cache before its session comes back.

Decisions (user, 2026-09-24):

- **The limit is memory in bytes, not a number of sessions.** No fixed session count stays in the code.
- **An entry that does not fit in memory goes to disk and comes back.** The fork writes it in a folder for each process under the temporary directory, and deletes the folders of dead processes at start.
- **The Router sizes the byte budget** from the pool: the recommended working set minus the footprints of the resident entries (weights plus one KV estimate for each slot hold; many sessions share one hold). Resident prompt-cache memory is `memoryBytes + spillingBytes` (an entry that is being written to disk is still in memory).
- **Each session has its own cache key.** The per-session wrapper binds the fork's task-local `MLXLanguageModel.promptCacheScope` to `.session(<session ULID>)` inside its executor `respond`, on the same task as the inner executor call. A fork thus has its own key, and a compaction keeps the key. A summarizer backend binds `.uncached` and keeps nothing. Do not bind `.none`: the task-local has the type `PromptCacheScope?`, so `.none` is `Optional.none` (no scope, the first-entry-id rule), and the compiler gives no error.
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
| ^6wqketz | Each summarizer call on the queue of its own container | ^93kjn94 |
| ^ake8sax | A queue wait is not a stall; tell the consumer about the wait | ^93kjn94 |
| R1 ^tv2yt7s | Size the prompt-cache byte budget from the pool | ^8nqkten, fork ^zcys2qw |
| R2 ^cc2tezn | A cache key for each session, and a release on close | ^8csj2hw, fork ^2mk47nr, ^zcys2qw |
| R3 ^ptev9yy | Summarizer calls keep no cache | ^6wqketz, R2, fork ^2mk47nr |
| ^f33q8gw | Rename the turn level to "request" | ^44y6ba4 |
| ^njdp02p | Design: mail and compaction at each pass | ^44y6ba4 |

The board cannot link a task on the fork board. A Router task that needs a fork task carries the tag `needs-fork` until that fork task is merged on the fork's `stable` branch and the Router pin is bumped.
