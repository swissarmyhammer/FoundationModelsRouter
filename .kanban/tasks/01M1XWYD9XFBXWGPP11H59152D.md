---
comments:
- actor: claude-code
  id: 01m1xxdgaskj8cjt4qc18naw3j
  text: |-
    Research before the edit.

    Root cause of item 4, found in the dependency source. `MLXLanguageModel.loadContainer()` goes to `ModelCache.load` (`.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift`), which puts the loader closure in an UNSTRUCTURED `Task { }` and then does `try await loadTask.task.value`. An unstructured task does not take its awaiter's cancellation, and `Task.value` does not throw when the awaiter is cancelled. So a cancelled resolve waits for the whole download. That is exactly the "the cancel has no effect" the card reports.

    The Hugging Face client already keeps the part files. `HubClient+Files.swift` writes each blob to `<etag>.incomplete`, sends `Range: bytes=<offset>-` on the next attempt, and re-throws `CancellationError` instead of falling back to the cache. So the router must not delete the cache, and it does not.

    Item 2 meets a standing invariant. `AsyncSemaphore.wait()` is intentionally non-throwing: `RoutedSessionActor.turnLock`, `ResidentModelGates.generation` and `forkAdmission` all depend on a cancelled waiter still acquiring in turn, so both gates stay balanced. `Tests/FoundationModelsRouterTests/AsyncSemaphoreTests.swift` has `cancelledWaiterDoesNotLeakOrStrand`, a regression test for that contract. Making `wait()` itself throw would break the session gates and a model-wide deadlock is the known failure mode.

    So the cancellation path is added as a SECOND acquire, `waitUnlessCancelled()`, and only `Router.poolLock` uses it. The card's requirement is met in substance — a cancelled waiter leaves the queue, the queue stays fair for the callers that remain, each continuation resumes one time — and the session gates keep the contract they need. The state gains a FIFO id order beside two continuation maps, so one arrival order serves both kinds of waiter.

    Test scaffolding that already exists. `PooledResidencyTests.StubModelLoader` has `gatedRef` / `entrySignal` / `releaseGate`: `loadLLM` for the gated ref signals it was reached and then waits, which is a deterministic suspension window inside an in-flight resolve. That is the window the pool-lock cancellation test needs.
  timestamp: 2026-09-07T12:27:46.905027+00:00
- actor: claude-code
  id: 01m1xzf77m793yqj7ektz977tt
  text: |-
    Implementation landed. Items 1, 2, 3 and 5 of the card are complete, and item 4's code change is complete. Item 4's fourth test shape is blocked — see the blocker comment that follows.

    What changed.

    `Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift` — a second acquire, `waitUnlessCancelled()`, that throws `CancellationError` and takes the caller out of the FIFO queue. State now holds one arrival order of tickets beside two continuation maps, one for each acquire, so the queue stays fair whichever acquire a caller took. A cancellation that arrives before the caller reaches its suspension point is recorded against its ticket and read at that point, so each continuation resumes exactly one time whichever side wins the race. `wait()` keeps its non-throwing contract for the session gates.

    `Sources/FoundationModelsRouter/Concurrency/CancellableWait.swift` — new. `CancellableWait.value(_:)` runs work that cannot itself be cancelled and stops awaiting it the moment the caller is cancelled. The work runs on, which is what keeps the part files filling the Hugging Face cache.

    `Sources/FoundationModelsRouter/Router.swift` — `runResolve` takes the pool lock with `waitUnlessCancelled()`, and opens each stage with `try Task.checkCancellation()`: before sizing, after sizing, before each generation slot, before the embedding slot, before each preload, and before `complete`. The existing `defer { poolLock.signal() }` frees the lock and the existing `catch` gives back every slot the attempt held, so requirement 5 needed no new code.

    `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` — both container loads go through `CancellableWait.value`.

    New tests, all in the unit target.

    - `AsyncSemaphoreTests`: a cancelled `waitUnlessCancelled` waiter leaves the queue and throws; the next signal reaches the caller that still waits; an already-cancelled caller takes no permit; an uncancelled cancellable waiter keeps its FIFO turn beside plain waiters. The standing `cancelledWaiterDoesNotLeakOrStrand` test for the non-throwing `wait()` is untouched and still passes.
    - `CancellableWaitTests`: the value and the error reach the caller; a cancelled caller throws while the work runs on to completion; a caller cancelled before the call never starts the work.
    - `ResolveCancellationTests`: one test for each stage (sizing, generation, embedding, preload) and one for a resolve cancelled while queued on the pool lock. Each asserts `CancellationError`, that the progress never reaches `.ready`, and that a later resolve on the same router completes — which is how a test outside the module reads that the pool lock is free.

    Red was watched. `ResolveCancellationTests` was run against the unchanged `Router.swift`: the run HUNG and was killed at 25 minutes, because the cancelled resolve never stops. That is the defect the card reports, reproduced.

    Verification: `swift test` — 1232 tests in 134 suites passed, plus 83 tests in 10 suites, zero failures, zero warnings, 2 pre-existing known issues. One earlier full run had `ToolInvocationLivenessTests` "a background call that attaches produces its report on streamSessionEvents() after the close record" fail on its 5-second `BoundedWait` ceiling; that suite passed three times in isolation and the failure did not repeat over two later full runs, so it is a load-dependent flake in a pre-existing test rather than a regression.
  timestamp: 2026-09-07T13:03:40.276353+00:00
- actor: claude-code
  id: 01m1xzfrh5r7ngw53jryw7senc
  text: |-
    Blocker: the fourth test shape cannot be written honestly. A person must decide.

    The shape: "A test cancels a resolve during the download, then starts a second resolve. The second resolve continues from the part files in the cache."

    Why it cannot be a unit test. The resume itself is not this repo's code. The part files and the `Range: bytes=<offset>-` request belong to swift-huggingface's `HubClient`, and the coalescing of a second load onto an in-flight one belongs to the MLX `ModelCache`. A stub loader in the unit target models neither, so a unit test of this shape would assert the stub rather than the behaviour.

    Why the integration test conflicts with a rule. The Hugging Face blob cache is shared across runs and is warm on any box that already holds the models. On such a box the test downloads nothing, cancels nothing, and passes without exercising the resume. `test-integrity/no-test-cheating` states "Every test should be run when we run tests, and every test should be able to fail", and a test that passes vacuously on a warm cache cannot fail.

    A cold cache would fix that: `#hubDownloader(_ hub:)` takes a `HubClient`, so a `HubCache` in a temp directory makes each run genuinely download. But `Router.resolve` needs a whole trio, and the trio the gated suite names is a 30B generation model in both generation slots plus an embedder. The gated suite runs in about 47 seconds today because that cache is warm, and it stands under `integrationTestBudgetMinutes`. A cold trio download on every run does not fit that budget.

    So the two requirements cannot both be correct: the card asks for this test, and the test-integrity rule forbids the only affordable form of it.

    What IS proven about item 4. The code change is done and tested. `CancellableWaitTests` "a cancelled caller throws while the work runs on to completion" proves the half this repo owns: the cancel stops the caller and never aborts the transfer, so the bytes already fetched are kept and the transfer finishes. What is not proven here is the half owned by swift-huggingface and the MLX model cache — that a later resolve continues from those bytes rather than starting again.

    Options for the person who decides:

    1. Accept the `CancellableWait` test as the coverage for item 4 and strike the fourth test shape from the card.
    2. Ask for a cold-cache integration test over a small trio (a small generation repo in both generation slots plus the existing embedder), and raise the integration budget to match. That is a new card, because it needs a small-model profile the target does not have today.
    3. Ask for a fake `Downloader` fixture in the integration target that models the part file and the `Range` request, proving the router's use of the contract rather than swift-huggingface's implementation of it.
  timestamp: 2026-09-07T13:03:57.989262+00:00
- actor: claude-code
  id: 01m1xzg11r62en9931fv2fbjd2
  text: |-
    ### implement — stuck
    - evidence: 7 files. Changed: Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/AsyncSemaphoreTests.swift. Added: Sources/FoundationModelsRouter/Concurrency/CancellableWait.swift, Tests/FoundationModelsRouterTests/CancellableWaitTests.swift, Tests/FoundationModelsRouterTests/ResolveCancellationTests.swift. `swift test` — 1232 tests in 134 suites passed and 83 tests in 10 suites passed, zero failures, zero warnings, 2 pre-existing known issues. Card items 1, 2, 3 and 5 are complete, and item 4's code change is complete. The gap is the fourth listed test shape, "cancel a resolve during the download, then a second resolve continues from the part files": it cannot be written without either a stub that asserts itself or an integration test that passes vacuously on a warm Hugging Face cache. See the blocker comment above.
    - next: a person picks one of the three options in the blocker comment. The code is green and ready for review either way.
  timestamp: 2026-09-07T13:04:06.712110+00:00
position_column: doing
position_ordinal: '80'
title: Stop Router.resolve when the caller cancels the Task
---
## What

`Router.resolve(profile:reporting:)` does not stop when the caller cancels its Task. Make it stop.

1. `resolve` (Sources/FoundationModelsRouter/Router.swift:228) calls `runResolve` (Router.swift:254). No file in `Sources/FoundationModelsRouter` outside `Session/` and `Hosting/` contains `Task.checkCancellation`, `Task.isCancelled` or `withTaskCancellationHandler`. Thus the resolve path makes no cancellation check.

2. `runResolve` waits on the pool lock at Router.swift:259, and releases it at Router.swift:260. The lock is `AsyncSemaphore(value: 1)` at Router.swift:148. `AsyncSemaphore.wait()` (Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:34) suspends in `withCheckedContinuation` with the failure type `Never`. Thus a cancelled waiter stays in the FIFO queue, and only a subsequent `signal()` releases it. Give `wait()` a cancellation path. A caller that the user cancels while it waits must leave the queue and return. The queue must stay fair for the callers that remain, and each continuation must resume one time only.

3. `runResolve` then does the slow work: it sizes the candidates, it acquires each generation slot, it acquires the embedding slot, and it preloads the three slots. Make a cancellation check before each stage. A cancelled resolve must stop at the next stage boundary and throw `CancellationError`.

4. The download is the longest stage. `LiveModelLoader` calls `loadContainer()` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:433) and `EmbedderModelFactory.shared.loadContainer` (LiveModelLoader.swift:446). Carry the cancellation into the transfer. Keep the part files in the Hugging Face cache. Thus a subsequent resolve continues the download and does not start it again.

5. The router state must stay correct after a cancelled resolve. The pool lock must be free. A slot that the cancelled resolve did not complete must not be resident.

## Test shape

- A test cancels the Task that holds `resolve` while a different resolve holds the pool lock. The cancelled call throws `CancellationError` before the other call sends `signal()`.
- A test cancels a caller of `AsyncSemaphore.wait()` and shows that the waiter count decreases. The subsequent `signal()` goes to the caller that still waits.
- A test cancels a resolve in each stage. The router does not become `.ready`, and the pool lock is free after the throw.
- A test cancels a resolve during the download, then starts a second resolve. The second resolve continues from the part files in the cache.

## Why

FoundationModelsACPAgent card ^54ay5s0 gives the agent CLI a `Ctrl-C` watch for the composition window. The watch cancels the composition Task, and that Task calls `Router.resolve`. Today the cancel has no effect: the user sees the download continue to its end. The agent side is written, and it waits for this change.