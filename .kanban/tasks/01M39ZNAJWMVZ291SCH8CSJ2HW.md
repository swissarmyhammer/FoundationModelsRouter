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
- actor: claude-code
  id: 01m3cc18jw691vktapagysah9z
  text: |-
    Research done. Findings:
    - `ResidentModelGates()` is made in `ModelPool.acquire` after `load()` returns. `MLXFoundationModelsContainer` is a struct that `LiveModelLoader.loadLLM` makes one time for each pool entry. Thus option (a): the container makes and owns one `GenerationQueue` (a class, so struct copies share it). The pool does not need to read the queue in this task, so no `LoadedLLMContainer` requirement is added.
    - `MLXFoundationModelsSessionBackend` keeps `model` for forks and for the `as? MLXLanguageModel` cast. Plan: the backend keeps the RAW model and the queue, and builds each `LanguageModelSession` (first session, fork, replaced transcript) over a NEW per-session wrapper. The cast then still finds the raw model.
    - `LiveModelLoader.evict(container:)` reads `container.model` (raw). No change there.
    - `RoutedModel.makeRecordingLanguageModelHandle` is the only production site of `RecordingLanguageModelState(...)`; it reads `container.languageModel`. The live container will return a new queued wrapper on each read.
    - `RecordingLanguageModelTests.generationGateSerializesAcrossHandles` is the test that pins the gate.
    - `StubSessionBackend` does not script a tool loop. The stubs that script a tool loop are the scripted `LanguageModel`s behind `LiveBackendContainer` (production backend), so they get the queue through the production backend.
  timestamp: 2026-09-25T13:28:18.268350+00:00
- actor: claude-code
  id: 01m3ccx2m0n1jd6thxz4d1a0kh
  text: |-
    Implementation landed (not committed). What changed:
    - New `Concurrency/GenerationQueue.swift`: `public final class GenerationQueue` over `AsyncSemaphore(value: 1)`, with `public func runPass(isolation:_:)` (= `withPermitUnlessCancelled`: waitUnlessCancelled, body, signal in a defer). It is a different semaphore from `generationGate`.
    - New `Concurrency/QueuedLanguageModel.swift`: `QueuedLanguageModel` + `QueuedLanguageModelState` (final class: `wrapped`, `queue`; R2 can add the session ULID here). `Executor.Configuration` compares and hashes by the identity of the state. The executor runs one pass of the inner executor inside `queue.runPass`, on the same task.
    - New `Core/ExecutorPassthrough.swift`: the build-the-inner-executor-once helper, MOVED out of `RecordingLanguageModelState.makePassthrough` so Recording and the queued wrapper share one copy.
    - `MLXFoundationModelsContainer` owns `let generationQueue = GenerationQueue()` (option (a)). `languageModel` gives a NEW per-session `QueuedLanguageModel` on each read. The backend keeps the RAW model and the queue; its two convenience inits (instructions / transcript) build each `LanguageModelSession` over a new wrapper. `makeFork(tools:)` and `replacingTranscript(_:)` make a new wrapper on the same queue. The file-private `makeSessionBackend` function is gone (the transcript init took its `String??` instructions rule). `mlxLanguageModel` reads the raw model for `respondWithoutReasoning`. `evict(container:)` still reads the raw `container.model`.
    - Recording: `RecordingLanguageModelState` has no `generationGate` now. It has its own `recordingLock` for each handle, held around diff-and-record only (generate, sync, noteCompaction). The inner executor call runs outside the lock; the queue is the job of the wrapped `container.languageModel`.
    - No `LoadedLLMContainer` requirement was added. `beginTurn`/`endTurn` are unchanged.

    Step 4 decision (answer for the ACP consumer ^sj4hczd): option (a). A container with no executor seam gets no pass-level gating from the Router; it still gets the turn-long `generationGate`. `GenerationQueue` is PUBLIC, so a consumer's stub container owns its own queue and runs each scripted pass in `queue.runPass { ... }`. A compile-proof test over a plain import is in `Tests/FoundationModelsRouterPublicSurfaceTests/GenerationQueuePublicSurfaceTests.swift`. Inside this repo, the test `LiveBackendContainer` owns a queue and uses the production backend, so every scripted tool loop behind it takes the queue for each pass. `StubSessionBackend` scripts no tool loop and gets no queue. The decision is also written in the docs of `LoadedLLMContainer` and `GenerationQueue`.

    Discovery (important for R2 ^cc2tezn and ^ake8sax): with this SDK, two `LanguageModelSession`s do NOT share an executor even over the SAME model value with EQUAL executor configurations (probe: two sessions over one `PassObservingModel` instance recorded two executor identities). The SDK builds executors per session, and reuses one executor across the turns of one session. Thus the identity key of the wrapper is a defense for a future SDK that caches across sessions; the session-level test "each session gets its own executor" cannot be made to fail by a key-only mutation. The key contract is pinned directly by `wrappersOverOneQueueCompareByTheirOwnState`.

    Mutation checks done: (1) remove `runPass` from the wrapper executor: the no-overlap test, the cancellation test and the Recording queue test fail; (2) make `runPass` skip the wait: the public-surface test fails; (3) key by queue only: the configuration test fails.
  timestamp: 2026-09-25T13:43:29.664974+00:00
- actor: claude-code
  id: 01m3ccx88vnck8e30tznqpnqwe
  text: |-
    ### implement — changed
    - evidence: files — Sources/FoundationModelsRouter/Concurrency/GenerationQueue.swift (new), Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift (new), Sources/FoundationModelsRouter/Core/ExecutorPassthrough.swift (new), Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Resolution/ModelLoader.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/GenerationQueueTests.swift (new, 6 tests), Tests/FoundationModelsRouterTests/Helpers/PassObservingModel.swift (new), Tests/FoundationModelsRouterTests/Helpers/LiveBackendContainer.swift, Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift, Tests/FoundationModelsRouterPublicSurfaceTests/GenerationQueuePublicSurfaceTests.swift (new, 1 test).
    - tests: `swift build --build-tests` 0 compiler warnings (only the known mlx bundle line); `swift test` root: 1396 tests in 159 suites passed (2 known issues, both pre-existing withKnownIssue), plus 2 and 19 tests in the other targets passed; GenerationQueueTests + RecordingLanguageModelTests 16/16, and 8 parallel processes x 200 repetitions all passed; IntegrationTests package builds; gated `LanguageModelSessionBackendIntegrationTests` + `ExecutorPassBoundaryIntegrationTests`: 14 tests in 2 suites passed over real MLX (the KV-cache reuse test passes through the wrapper).
    - next: /review
  timestamp: 2026-09-25T13:43:35.451013+00:00
- actor: claude-code
  id: 01m3cer51sh0bex85sekqnwqvq
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD. 3 findings, 3 confirmed, 0 refuted. Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:269, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:298, Tests/FoundationModelsRouterTests/GenerationQueueTests.swift:160
    - next: Correct the 3 open items in the "Review Findings (2026-09-25 08:51)" section. The task stays in review.
  timestamp: 2026-09-25T14:15:45.465866+00:00
- actor: claude-code
  id: 01m3cew5jpk8zjm7nq0ckhtdx8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 13 files
    - test: green — swift test, 1417 passed (1396+2+19), 0 failed, 0 skipped; 5 extra runs of the concurrency suites clean; IntegrationTests build clean
    - commit: 2e97dac
    - review: findings — Resolution/LiveModelLoader.swift:269, Resolution/LiveModelLoader.swift:298, GenerationQueueTests.swift:160
  timestamp: 2026-09-25T14:17:57.078452+00:00
- actor: claude-code
  id: 01m3cfm2qwtj4m42x51haxgz2f
  text: |-
    Review findings fixed (2026-09-25 08:51 section).
    - LiveModelLoader.swift: the private designated init of MLXFoundationModelsSessionBackend now takes a `makeSession: (QueuedLanguageModel) -> LanguageModelSession` closure in place of a finished session. The designated init is now the one place that makes the per-session QueuedLanguageModel. Each convenience init gives only its LanguageModelSession variant (instructions or transcript) and its instructions. The file has no other copy of the wrapper-and-init pattern. The `languageModel` property of the container makes one wrapper and calls no init, so it stays.
    - GenerationQueueTests.swift: the tautology `first.executorConfiguration == first.executorConfiguration` is removed. No other tautology is in the file. The stable key of one wrapper is already proved through a real path: `eachSessionOverOneContainerGetsItsOwnExecutor` runs two passes of one session and expects one executor (`firstExecutors.count == 1`).
    - Note: the build shows `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle`. This is a SwiftPM build-graph message about the MLX resource bundle, not a compiler warning, and it is not from this change.
  timestamp: 2026-09-25T14:31:00.604060+00:00
- actor: claude-code
  id: 01m3cfmghva8d6fqccz1g7r82n
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/GenerationQueueTests.swift. `swift test` at root: 1396 tests in 159 suites passed (2 known issues), plus 2 and 19 tests in the other test bundles; `--filter GenerationQueueTests`: 6 tests passed; `swift build --build-tests` in IntegrationTests/: Build complete (178.57 sec, recompiled). 3 of 3 findings checked.
    - next: review
  timestamp: 2026-09-25T14:31:14.747489+00:00
- actor: claude-code
  id: 01m3chrqshpb7bfzjaqzzx7hd8
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 8b8a5e1) gave 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed). The engine reviewed 2 files. It did not review 2 files in `.kanban/` because of `.reviewignore`. The 3 prior findings are all checked, and the code resolves them. The two convenience `init` methods in `LiveModelLoader.swift` now call one private designated `init`. That `init` makes the `QueuedLanguageModel` wrapper and receives a `makeSession` closure. The tautological assertion is removed from `GenerationQueueTests.swift`.
    - next: The task is in done. The blocked tasks ^93kjn94 and ^cc2tezn can start.
  timestamp: 2026-09-25T15:08:30.385032+00:00
- actor: claude-code
  id: 01m3chw1fjmrkwgj6kp5bth4te
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 files (one designated init builds the queued wrapper; tautology removed)
    - test: green — swift test, 1417 passed (1396+2+19), 0 failed, 0 skipped; concurrency suites 3 extra runs clean; IntegrationTests build clean
    - commit: 8b8a5e1
    - review: clean — 0 findings
  timestamp: 2026-09-25T15:10:18.610731+00:00
depends_on:
- 01M39ZMNME683Y75PX48NQKTEN
position_column: done
position_ordinal: ffffff8380
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

- [x] Two `LanguageModelSession`s over the same pool entry never run two executor passes at the same time (test with an executor-level scripted model that counts concurrent passes, for example with `ConcurrencyPeakObserver`).
- [x] Two sessions over one container get two executors: the executor of one session never runs a pass of the other (test that records the per-session state each pass sees).
- [x] A pass that waits for a queue place and is cancelled throws `CancellationError` and does not leave a place taken (the permit count is 1 after).
- [x] `respondWithoutReasoning` still turns thinking off for a template-flag model (test that the raw model is found).
- [x] The Recording path records the same events as before. `RecordingLanguageModelTests` stay green, except the test that pins the gate, which changes to the new lock.
- [x] Nothing in this task changes `beginTurn`/`endTurn`. The full suite is green. #generation-queue

## Review Findings (2026-09-25 08:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:269` `duplication/duplication` — Two convenience `init` methods (lines 269–282 and 298–313) duplicate the pattern of creating a `QueuedLanguageModel` wrapper and calling the designated `init`. They differ only in how `LanguageModelSession` is constructed (with `instructions` vs `transcript`) and how the final `instructions` parameter is derived. This repeated structure should be extracted into a helper method to avoid drift. Extract a private helper method that accepts both the model and instructions as parameters, wraps it in `QueuedLanguageModel`, creates the session, and calls the designated init. Alternatively, add a parameter to one of the convenience inits to accept a pre-built or conditionally-built `LanguageModelSession` so the two methods can share the common boilerplate.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:298` `duplication/duplication` — Second convenience `init` method (lines 298–313) duplicates the structure of the first (lines 269–282). Both create a `QueuedLanguageModel` and call the designated `init` with nearly identical parameter-passing logic. The only meaningful differences are in the `LanguageModelSession` variant and instructions derivation, which should be parameterized rather than copy-pasted. See line 269 fix: extract the common pattern into a shared helper method or combine the logic so both variants call a single helper that accepts the key differences as parameters.
- [x] `Tests/FoundationModelsRouterTests/GenerationQueueTests.swift:160` `test-integrity/no-test-cheating` — The assertion `first.executorConfiguration == first.executorConfiguration` is a trivial tautology that always passes and proves nothing meaningful. It only checks reflexivity of equality, which any equality operator must satisfy by design, regardless of whether the actual behavior being tested (different wrappers having different executor configurations) works correctly. Remove line 160. The test's purpose is fully verified by the assertion on line 161: `#expect(first.executorConfiguration != second.executorConfiguration)`. If testing equality operator behavior is necessary, it should be in a separate dedicated test.
