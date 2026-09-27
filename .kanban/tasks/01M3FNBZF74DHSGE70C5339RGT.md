---
assignees:
- claude-code
depends_on:
- 01M3FNJS6J7KGAJJ5WFEST00WA
position_column: todo
position_ordinal: '9e80'
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