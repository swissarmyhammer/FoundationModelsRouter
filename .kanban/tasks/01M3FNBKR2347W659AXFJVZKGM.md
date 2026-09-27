---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hvp71j7y49hfsdr07afgay
  text: |-
    Research (Extras at f4bd503, `.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/ModelPool/`). Differences between the task text and the code (the code wins):
    - `ModelPoolKey` has the init `ModelPoolKey(ref:role:)` with labels.
    - `PooledModelLoader.load(_ key: ModelPoolKey) async throws -> any Sendable` and `evict(_ container: any Sendable) async`. The container type is `any Sendable`, not a router type.
    - `ModelPool.acquire(_ key:footprintBytes:sessionBytes:loader:) async throws -> ModelHold`. The same signature is on `ModelPoolAdmission`.
    - `ModelHold` has `key`, `container: any Sendable` and `queue: GenerationQueue`.
    - `PooledEmbedder(hold:)` throws `PooledEmbedderError.notAnEmbedding(key:containerType:)` when the container does not conform to `PooledEmbedding`. Its `embed(texts:)` runs as one job in the queue of the hold.
    - `ModelPoolFootprint` has `resident`, `loadingBytes` and `totalBytes`.
    Router facts:
    - The router makes no cast to `LoadedEmbeddingContainer` now. The live loader ignores `slot` and `context`; only `reporting` has an effect.
    - The task text names lines 822, 907, 1008 and 1018. These numbers do not match the current files. The slot data that a load needs is the slot, the advisory context and the progress callback (`Router.acquireLLM` and `Router.acquireEmbedder`).
    Plan: aliases `ModelRole`, `ModelPoolKey`, `PooledModelLoader`, `PooledEmbedding` in a new file; `ModelSlot.poolRole`; `LoadedEmbeddingContainer` refines `PooledEmbedding`; `LiveModelLoader` conforms to `PooledModelLoader` with a new init parameter `reporting` (default: no operation); a new internal adapter `SlotPoolLoader` gives the slot data of the router when the router makes it, and gives `acquireEmbedder` (through `PooledEmbedder`) and `acquireGeneration` (cast to `LoadedLLMContainer`, clear error on failure). `Router.resolve` does not change.
  timestamp: 2026-09-27T16:38:05.618842+00:00
- actor: claude-code
  id: 01m3hvxmrn1t16pnb6ky3wvfp8
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Resolution/PoolPrimitives.swift (new: aliases ModelRole, ModelPoolKey, PooledModelLoader, PooledEmbedding), Sources/FoundationModelsRouter/Resolution/SlotPoolLoader.swift (new: SlotPoolLoader, ModelHold.generationContainer(), PooledGenerationError), Sources/FoundationModelsRouter/Core/ModelSlot.swift (poolRole), Sources/FoundationModelsRouter/Resolution/ModelLoader.swift (LoadedEmbeddingContainer refines PooledEmbedding), Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift (conforms to PooledModelLoader; new init parameter `reporting`), Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift (7 tests). `swift test --skip-build --filter SlotPoolLoaderTests`: 7 tests in 1 suite passed.
    - Decision: the router gives the slot, the context and the progress callback through `SlotPoolLoader`, which it makes for each slot. `Router.resolve` does not change; task 01M3FNJS6J7KGAJJ5WFEST00WA uses `SlotPoolLoader.acquireHold`, `PooledEmbedder(hold:)` and `ModelHold.generationContainer()`.
    - next: /test
  timestamp: 2026-09-27T16:42:09.045790+00:00
depends_on:
- 01M3FNB4MCRRBTJNNVZZ6P02R2
position_column: doing
position_ordinal: '80'
title: 'Router: make the router loader conform to the Extras pool loader protocol, and map ModelSlot to a role'
---
## What
Decision (user, 2026-09-26): the router uses the process-wide `ModelPool` in the core `FoundationModelsExtras` target (no new product or target), so that the router, the registry, the multitool and other users share one copy of each model in memory.

Blocked by Extras task 01M3FN95AM98RJSTCVQ8G1Z7KE. That task defines the names of the loader protocol, the hold type and the embed protocol. Use those names. The Extras names are (read the final API in the Extras task description): `final class ModelPool` (not an actor; `footprint`, `residentModelCount` and `isResident` are synchronous), `ModelRole { llm, embedding }`, `ModelPoolKey(ref, role)`, `protocol PooledModelLoader` (`load(_ key: ModelPoolKey)`, `evict(_ container:)`), `final class ModelHold` (releases synchronously in its deinit), `admit { admission in ... }` with `ModelPoolAdmission` (`footprint`, `acquire`), `acquire(...)`, the `footprints` stream of `ModelPoolFootprint`, and `protocol PooledEmbedding { dimension; embed(texts:) }` with `struct PooledEmbedder` (Extras task 01M3FN9BTXNPBWE6VVBQEXK4W2). Here, "the Extras loader protocol" is `PooledModelLoader` and "the Extras embed protocol" is `PooledEmbedding`. The Extras work must be pushed first.

This task prepares the router types. It does not change `Router.resolve` (task 01M3FNJS6J7KGAJJ5WFEST00WA does that; task 01M3FNK00PYXP7E102NWNHMD56 does the prompt cache observer).

- `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift` and `LiveModelLoader.swift`: the router loader conforms to the Extras loader protocol, which loads by `ModelRef` and role only. The router gives the slot data that the load needs (lines 822, 907, 1008, 1018) when it makes the loader, not through the pool. The `evict` step goes through the Extras protocol.
- Make `LiveModelLoader` usable by a caller that is not the router: an application can make one and give it to the Extras pool, for example for the registry. Its public init must not need a `Router`.
- Map `ModelSlot` (standard, flash, embedding) to the Extras pool role in the router. `ModelSlot` stays a router type.
- `LoadedEmbeddingContainer` conforms to the Extras embed protocol (`dimension`, `embed(texts:)`).
- The pool uses the loader of the first caller of a key. Thus the router must not cast an embedding container to `LoadedEmbeddingContainer`. It uses the Extras embed protocol. For a generation container, the router casts to `LoadedLLMContainer` and throws a clear error if the cast fails.

## Acceptance Criteria
- [ ] `LiveModelLoader` conforms to the Extras loader protocol and has a public init that does not need a `Router`.
- [ ] `LoadedEmbeddingContainer` conforms to the Extras embed protocol.
- [ ] No router code casts an embedding container to `LoadedEmbeddingContainer`.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add a test in `Tests/FoundationModelsRouterTests/`: each `ModelSlot` maps to the expected pool role.
- [ ] Add a test: a stub loader A (not the router's) loads an embedding key in a private pool first; then the router path acquires the same key and embeds through the Extras embed protocol with the container of loader A.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo