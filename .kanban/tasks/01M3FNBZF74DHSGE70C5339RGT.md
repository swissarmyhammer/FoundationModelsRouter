---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3m127c3nt368xfpyv7m02sn
  text: |-
    Research (Extras at 4a733cd, `.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/ModelPool/`). Differences between the task text and the code (the code wins):
    - The Extras work is in the checkout: `ModelPool.Entry` makes `let queue = GenerationQueue()`, and `ModelHold.queue` gives it. All holds of one key share it. The entry makes the queue AFTER `loader.load(key)` returns. Thus a loader cannot give the queue to the container that it makes. The router must give the queue to the container after it gets the hold.
    - `PooledEmbedder(hold:)` runs each `embed(texts:)` as one job in `hold.queue`. The router already uses it: `PooledEmbeddingContainer` (task ^est00wa) wraps it, and `RoutedEmbedder.embed` calls `container.embed`. Thus the embed part of this task is done in the code; this task adds its test only.
    - `RoutedEmbedder.swift:51` calls `container.embed`, and `container` is a `PooledEmbeddingContainer`, not the loader container.
    - The `LanguageModelSessionBackend.generationQueue` requirement is at line 239 (not 236).
    Plan:
    - `LoadedLLMContainer` gets a new requirement `submitting(to queue: GenerationQueue) -> any LoadedLLMContainer`: a copy of the container whose backends name `queue`. The default gives `self` (a container that names no queue, or its own queue, does not change).
    - `ModelHold.generationContainer()` gives `container.submitting(to: queue)`. Thus each session backend of a routed handle names the queue of the pool entry.
    - `MLXFoundationModelsContainer` makes no queue: `generationQueue: GenerationQueue?` is `nil` from the loader, and `submitting(to:)` sets it. `MLXFoundationModelsSessionBackend` keeps an optional queue.
    - Test helper `LiveBackendContainer` makes no queue: the caller gives it, and `submitting(to:)` replaces it. The eval container of IntegrationTests binds the loaded container to a queue that the eval makes, because it uses the container outside the pool.
    - Side effect: `StubModelLoader` gives one container object for `standard` and `flash`. These are two pool keys, so two entries and two queues. Before, the two slots shared the one queue of that container.
  timestamp: 2026-09-28T12:50:30.915091+00:00
- actor: claude-code
  id: 01m3m2y40msbfh1e60vad0x21f
  text: |-
    ### implement — changed
    - evidence: Sources — ModelLoader.swift (new requirement `LoadedLLMContainer.submitting(to:)`, default gives `self`), SlotPoolLoader.swift (`ModelHold.generationContainer()` gives `container.submitting(to: queue)`), LiveModelLoader.swift (`MLXFoundationModelsContainer` makes no queue: `generationQueue: GenerationQueue?` is `nil` until `submitting(to:)`; the backend keeps `let generationQueue: GenerationQueue?`), QueuePrimitives.swift and RoutedSessionActorCompaction.swift (docs). Tests — new PoolEntryQueueTests.swift (two routers on one pool: each standard backend names `hold.queue`, three calls run one at a time in FIFO order; a router embed call and a direct `PooledEmbedder` share one load and one queue), new Helpers/RoutedLLMBackendQueue.swift (`RoutedModel.backendQueue`), Helpers/LiveBackendContainer.swift (no own queue; `submitting(to:)`), Helpers/PassObservingFixture.swift (the fixture queue stands in for an entry queue outside a pool), GenerationQueueTests.swift (the live container makes no queue, backend/fork/replaced transcript name the queue it gets), GenerationQueueSubmissionTests, QueuedPassStallWatchTests, NestedGenerationReentryTests, SummarizerSubmissionTests, ToolResultCompactionTests, SharedGenerationQueueContentionTests (read the queue from the resolved handle). RealModelContainer.swift and IntegrationTests CompactionEvalRealModelContainer.swift give the loaded container a queue, because they use it outside the pool. Docs — model-pool.md §2.7, generation-queue.md.
    - Discovery: `StubModelLoader` gives one container for `standard` and `flash`. These are two pool entries, so two queues now. Tests that read `fixture.queue` after a resolve read the wrong queue; they now read `backendQueue` of the handle.
    - The re-entrant wait check still throws on the entry queue (`anInBandWaitForASessionOnTheSameModelIsRefused` passes over a resolved profile).
    - Verification: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1466 tests in 178 suites passed (2 known issues), plus 17 and 19; queue/pool/cancellation/embedder suites (20 suites, 119 tests) 10 times with `--parallel --num-workers 8`, all passed; `--filter AnswerCancellation --parallel --num-workers 8` 10 times, 27 tests each time passed; `swift build --build-tests --package-path IntegrationTests` — Build complete, no warning.
    - next: /test
  timestamp: 2026-09-28T13:23:13.556847+00:00
- actor: claude-code
  id: 01m3m2yfmx3684qafw6br7f6rm
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` — Build complete, no source warning; `swift test --skip-build` — 1466 tests in 178 suites passed (2 known issues that two tests expect on purpose), plus 17 tests in 8 suites and 19 tests in 3 suites; no skipped test; `swift build --build-tests --package-path IntegrationTests` — Build complete, no warning; queue/pool/cancellation/embedder suites 10 times with `--parallel --num-workers 8` — 119 tests in 20 suites passed each time; `--filter AnswerCancellation --parallel --num-workers 8` 10 times — 27 tests passed each time.
    - next: /commit
  timestamp: 2026-09-28T13:23:25.469085+00:00
depends_on:
- 01M3FNJS6J7KGAJJ5WFEST00WA
position_column: doing
position_ordinal: '80'
title: 'Router: use the work queue of the pool entry, and send embeddings through it'
---
## What
Decision (user, 2026-09-26): all users of one model share one work queue, which the pool entry owns. Embeddings also go through that queue.

Blocked by Extras task 01M3FN9BTXNPBWE6VVBQEXK4W2 (the pool entry owns the `GenerationQueue`; an embedder handle runs each embed call through it and keeps the hold). The Extras work must be pushed first.

- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:60`: the MLX container stops making its own `GenerationQueue`. Each session backend gets the queue of the pool entry. `LanguageModelSessionBackend.generationQueue` (`LanguageModelSessionBackend.swift:236`) returns that queue.
- `Sources/FoundationModelsRouter/RoutedEmbedder.swift:51`: use the Extras embedder handle, so that each embed call waits in the queue of its model. Today it calls `container.embed` directly. `RoutedEmbedder.dimension` comes from the embedder handle, which reads it from the Extras embed protocol that `LoadedEmbeddingContainer` conforms to (router task 01M3FNBKR2347W659AXFJVZKGM).
- Keep the re-entrant wait check: a model call that waits inside an open submission on the same queue still throws `GenerationQueueError.waitInsideOpenSubmission`.
- Update the scripted and stub containers in `Tests/FoundationModelsRouterTests/Helpers/` if they make a queue of their own.

## Acceptance Criteria
- [ ] No router type makes a `GenerationQueue`. The queue comes only from the pool entry.
- [ ] Two sessions from two routers on the same model use one queue, and their model calls run one at a time in FIFO order.
- [ ] Router embed calls go through the queue of the embedding model.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add a test in `Tests/FoundationModelsRouterTests/`: two routers resolve the same `ModelRef`, and a model call from each goes through one queue in order (use real signals, not the wall clock).
- [ ] Add a test: a `RoutedEmbedder` embed call and a direct Extras embedder handle for the same key share one queue and one load.
- [ ] `GenerationStallDiagnosticTests`, `ExecutorPassBoundaryTests` and the re-entrant wait tests pass.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo