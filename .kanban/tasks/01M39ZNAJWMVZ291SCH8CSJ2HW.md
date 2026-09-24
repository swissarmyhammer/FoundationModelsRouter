---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39zq11qrwq9e3y63w9hh00b
  text: 'Order constraint: in this task the queue MUST be a semaphore different from the turn-long `generationGate`. The next task (^93kjn94) removes the turn-long gate. If the queue and the gate were one semaphore, a turn would hold the gate and then each pass would wait for the same semaphore: a deadlock on the first pass. With two semaphores, this task is safe to ship alone: the turn holds the gate, and each pass also takes the queue.'
  timestamp: 2026-09-24T15:14:31.095427+00:00
- actor: claude-code
  id: 01m39zrh3ebw4yepw745e68ygb
  text: |-
    Decision (user, through the FoundationModelsAgents session, 2026-09-24): one queue for each distinct model, NOT one global GPU queue. The queue belongs to the loaded container. Two slots that resolve to the same pool entry share one queue. Different models have their own queues and can generate at the same time, as now.

    Note: "the same model" here means the same pool entry. `ResidencyKey` is `(ref, role)` with `role = .llm(context:)` (see ^1zt7vyg). Two slots with the same ref and a different context are two entries, two containers, and thus two queues. This task keeps that behavior and does not change it.
  timestamp: 2026-09-24T15:15:20.302721+00:00
- actor: claude-code
  id: 01m3a3nzjwwsw3ptc4mssg9gcw
  text: 'Consumer need from FoundationModelsACPAgent (2026-09-24), for step 4: the ACP agent tests its queue behavior with a `LoadedLLMContainer` whose sessions are `LanguageModelSessionBackend` stubs (no executor seam). It needs one of: (a) stub containers take the queue for each scripted pass, as step 4 recommends, or (b) a public executor-level scripted model helper that the consumer can use. Please write the decision in a comment here. Consumer card: ^sj4hczd on the ACP board.'
  timestamp: 2026-09-24T16:23:51.132140+00:00
depends_on:
- 01M39ZMNME683Y75PX48NQKTEN
position_column: todo
position_ordinal: '8180'
title: Add the per-model generation queue at the executor seam and move Recording to its own lock
---
## Why

One GPU runs one generation at a time. Now a turn holds `ResidentModelGates.generation` for the whole turn, tool bodies included. Spike ^8nqkten proved that one executor call ends before the SDK starts the tool body of that call. Thus one queue item for each executor call (one pass of the tool loop) is safe. This task adds the queue and the wrapper. It does NOT yet remove the turn-long gate (^93kjn94 does that). Design: `generation-queue.md` (repository root), section 2.

## What to do

1. Add a `GenerationQueue` type over `AsyncSemaphore(value: 1)`, one for each pool entry. It is a DIFFERENT semaphore from `generationGate` in this task (see the order constraint below).
2. Add a queued `LanguageModel` wrapper, shaped like `RecordingLanguageModel` and its `Executor`. It is ONE INSTANCE FOR EACH BACKEND the container vends (each session, each fork, each summarizer backend). Each instance holds a small per-session state object (a class) with the queue of its container. All instances of one container share that queue.
   - Its executor `respond`: `try await queue.waitUnlessCancelled()`, then the inner executor for one pass (built once, called directly on the same task, as `RecordingLanguageModelState.makePassthrough` does), then `queue.signal()` in a `defer`.
   - Its `Executor.Configuration` compares and hashes by the IDENTITY of the per-session state object. It must not compare only by the queue and the inner configuration: the SDK caches executors by this key, so two sessions with equal keys would share one executor. R2 ^cc2tezn later binds the session's prompt-cache key in this executor, and ^ake8sax reports the queue wait to the session actor from it; both need one executor for each session.
3. Give the queue to the live container.
   - `ModelPool` makes the gates after the loader returns the container (`ModelPool.acquireModel` path, `ResidentModelGates()`). The container thus does not know a pool-owned queue. Choose one: (a) the container makes and owns the queue, and the pool entry reads it, or (b) `makeSession` receives the queue. Prefer (a): one resident container is one pool entry, so the identity is the same.
   - `MLXFoundationModelsContainer.makeSession` (all overloads) and `makeSessionBackend` build the per-session wrapper over the raw model, so each backend gets its own wrapper.
   - `LoadedLLMContainer` is a `public` protocol (`Resolution/ModelLoader.swift`). Breaking consumers is acceptable (user decision 2026-09-24), but add a protocol requirement only if it is necessary.
   - Keep a reference to the raw `MLXLanguageModel`. `modelTurnsThinkingOffByTemplateFlag()` in `MLXFoundationModelsSessionBackend` does `model as? MLXLanguageModel`; with the wrapper the cast fails and `respondWithoutReasoning` silently keeps thinking on. `LiveModelLoader.evict(container:)` also needs the raw model.
   - `makeFork(tools:)` and `replacingTranscript(_:)` of `MLXFoundationModelsSessionBackend` make a NEW per-session wrapper for the new backend (a fork is a new session), over the same queue.
4. A container with no executor seam (the test `StubSessionBackend` and its containers; a third-party `LoadedLLMContainer`) gets no pass-level gating from the wrapper. Decide and write down what they get. Recommendation: stubs that script a tool loop take the queue for each scripted pass, so the queue behavior is testable without MLX.
5. `RecordingLanguageModelState` takes `generationGate` around diff-and-record AND around `innerRespond` (`generate`, `sync`, `noteCompaction`, `enterGateAndRecordMeta`). When `container.languageModel` (used by `RoutedModel.makeLanguageModel()` in `RoutedLLM.swift`) is queued, Recording would wait on two semaphores. In the same change: give Recording its own lock for each handle for diff-and-record, and let the wrapper do the GPU queue. Do not ship this task in two parts.

## Order constraint

In this task the queue MUST be a semaphore different from the turn-long `generationGate`. ^93kjn94 removes the turn-long gate. If the queue and the gate were one semaphore, a turn would hold the gate and then each pass would wait on it: a deadlock on the first pass. With two semaphores, this task is safe to ship alone.

## Acceptance Criteria

- [ ] Two `LanguageModelSession`s over the same pool entry never run two executor passes at the same time (test with an executor-level scripted model that counts concurrent passes, for example with `ConcurrencyPeakObserver`).
- [ ] Two sessions over one container get two executors: the executor of one session never runs a pass of the other (test that records the per-session state each pass sees).
- [ ] A pass that waits for a queue place and is cancelled throws `CancellationError` and does not leave a place taken (the permit count is 1 after).
- [ ] `respondWithoutReasoning` still turns thinking off for a template-flag model (test that the raw model is found).
- [ ] The Recording path records the same events as before. `RecordingLanguageModelTests` stay green, except the test that pins the gate, which changes to the new lock.
- [ ] Nothing in this task changes `beginTurn`/`endTurn`. The full suite is green. #generation-queue