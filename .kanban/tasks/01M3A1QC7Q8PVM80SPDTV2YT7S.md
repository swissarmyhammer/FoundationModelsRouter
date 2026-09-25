---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a1y86psq3wcn9mpvcb3hhe
  text: 'Fork dependency (mlx-swift-lm board, 2026-09-24): ^zcys2qw (public budget API + release). API: `MLXLanguageModel.configurePromptCache(memoryBudgetBytes: Int) async` and `configurePromptCache(diskBudgetBytes: Int) async`, and `promptCacheUsage: (memoryBytes, diskBytes)` for tests. Fork defaults when the host sets nothing: memory = 25% of max(0, maxRecommendedWorkingSetSize - Memory.activeMemory) at first use; disk = 25% of the free space of the volume. Decide in this task if the Router also sets the disk budget. Risk from the fork (measured in fork ^mre55m3): a spill write holds MLX''s process-wide evalLock for the whole write, which stalls the generation of EVERY model. Read that measurement before you choose a large memory budget or a small one.'
  timestamp: 2026-09-24T15:53:24.950168+00:00
- actor: claude-code
  id: 01m3a2d8rt61pktr4hwvsptey6
  text: 'Fork API change (mlx board check, 2026-09-24): `promptCacheUsage` now gives `(memoryBytes: Int, spillingBytes: Int, diskBytes: Int)`. `spillingBytes` are entries that are being written to disk. They stay in memory until the write ends. Count memoryBytes + spillingBytes as resident memory in the pool sizing and in the tests of this task. The fork has one serial disk writer (one write at a time, because save() holds MLX''s process-wide evalLock). A burst of evictions thus waits in a queue, and spillingBytes can stay high for some time. Dependencies are unchanged: ^zcys2qw.'
  timestamp: 2026-09-24T16:01:37.050225+00:00
- actor: claude-code
  id: 01m3a5r13q41qp0bsyx2d6we26
  text: 'User decision (2026-09-24): a cold cache after a process restart is acceptable. No task keeps the prompt cache across a restart. The "Not in this task" item about a warm restore is thus closed: it is not done in any task. `generation-queue.md` section 3 records the decision.'
  timestamp: 2026-09-24T16:59:55.383086+00:00
- actor: claude-code
  id: 01m3c8khz105t1zwnwqcg9eyqf
  text: |-
    Research (implement step, 2026-09-25):
    - Fork pin: `swift package update mlx-swift-lm` in the root and in `IntegrationTests/` resolved both `Package.resolved` files to stable `ffac55d4e9e0f75d30347c561cea042b674be831` (remote `stable` head is the same). `swift build --build-tests` on the new pin: build complete, no Swift warnings.
    - Fork API at ffac55d matches the card. `ExecutorPromptCacheStore` caps only the in-memory entries (`retainedByteCount`) with `memoryBudgetBytes`. `spillingByteCount` is NOT in that cap. Thus the Router must hold the spilling bytes out of the budget it sends, if memory + spilling must fit in the pool remainder.
    - `ModelPool` has no probe; the Router has the probe. The pool does the insert and the evict (evict can come from a `ResidencyHold` deinit drain, with no Router on the stack). Thus the pool keeps, on each entry, the prompt-cache target and the working set of the resolve that loaded it.
    - Unit tests make ~77 `ModelPool()` values and all use stub loaders. To keep the live MLX store out of unit tests, the target comes from the loader: `ModelLoader` refines a new `PromptCacheBudgeting` protocol, with a no-op default. `LiveModelLoader` sends the budget to `MLXLanguageModel`.
    - Two pools: README and `model-pool.md` section 5 say a second pool is an isolated budget on purpose. The fork store is process-wide, so the budgets do not add: the last pool that sends a budget sets it.
  timestamp: 2026-09-25T12:28:23.393760+00:00
- actor: claude-code
  id: 01m3c9xmhbspm2m5xeqb261ehb
  text: |-
    Implementation landed (not committed):
    - Pin: both `Package.resolved` files (gitignored) resolve mlx-swift-lm `stable` to `ffac55d4e9e0f75d30347c561cea042b674be831`. The doc comment of `LiveModelLoader.configurePromptCache(memoryBudgetBytes:)` records the revision.
    - API: `ModelLoader` gets `configurePromptCache(memoryBudgetBytes:)` and `promptCacheUsage`, with no-op defaults (the prevailing `evict` pattern). New public `PromptCacheUsage` (memory, spilling, disk; `residentBytes` = memory + spilling). `LiveModelLoader` forwards both to `MLXLanguageModel`.
    - Budget: `PromptCacheBudget.memoryBudgetBytes` (Sizing/PromptCacheBudget.swift) = working set - sum of `PoolEntry.footprintBytes` - spillingBytes, clamped at 0. The fork caps only the in-memory entries, so holding the spilling bytes out keeps memory + spilling inside the pool remainder. Trade-off in the doc comment: the value stays conservative until the next footprint change after the writes end.
    - When: `ModelPool` sends it on each footprint change: before a fresh load (with the new footprint, so spills start while the weights load), after a failed load (gives the bytes back), on a hold added to a resident entry, and on each release (after the evict). It is NOT sent again after a successful load: the spills that the first send started would count as spilling bytes and shrink the budget a second time. Each `PoolEntry` keeps a `PromptCacheSizing` (the loader and the working set of its resolve), because an unload from a `ResidencyHold` drain has no Router on the stack. The Router passes its `totalBudget` (the probe working set) through `acquireLLM`/`acquireEmbedder`/`acquireModel`.
    - Disk budget decision: the Router keeps the fork default (a quarter of the free volume space). Comment in `LiveModelLoader`.
    - evalLock stall, the choice of the whole remainder (from the ^mre55m3 table), and how two pools combine (they do not add; the last pool that sends wins; one pool per process is the correct configuration): doc comment of `PromptCacheBudget`.
    - `Footprint` doc: it does not size recurrent (Mamba/SSM) state.
    - Unrelated flake seen: 1 of 24 full runs failed `HumanWaitGateTests` "a turn ending while a human wait's re-acquire..." with `SignalNeverArrived`; baseline 0 of 12, my tree 0 of 15 after. Filed ^1qpmghh.
  timestamp: 2026-09-25T12:51:22.283497+00:00
- actor: claude-code
  id: 01m3c9ynskyq8zw5fbjtckb068
  text: |-
    ### implement — changed
    - evidence: 10 files. Changed: Sources/FoundationModelsRouter/Resolution/{ModelLoader,ModelPool,LiveModelLoader}.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Sizing/Footprint.swift. New: Sources/FoundationModelsRouter/Sizing/PromptCacheBudget.swift, Tests/FoundationModelsRouterTests/PromptCacheBudgetTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PromptCacheBudgetIntegrationTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/SettledValuePoll.swift. Package.resolved (root and IntegrationTests, gitignored) -> ffac55d.
    - tests: `swift test --filter 'FoundationModelsRouterTests.PromptCacheBudgetTests'` 11/11 pass (seen RED first: 9 fail). Root `swift test`: 1389 tests in 158 suites pass, 2 known issues (both pre-existing withKnownIssue), 15 of 15 clean runs; one earlier run hit the unrelated flake ^1qpmghh. No build warnings on the recompiled files.
    - gated, real models: `PromptCacheBudgetIntegrationTests/` 1/1 pass with Qwen3-4B-4bit + Qwen3-1.7B-4bit + Qwen3-Embedding-0.6B-4bit-DWQ (RED first on the no-op loader: diskBytes == 0). `LanguageModelSessionBackendIntegrationTests/secondTurnReusesFirstTurnsKVCache` 1/1 pass on Muse-Glimmer-30B-mxfp4 at the ffac55d pin. `CrossRouterPoolIntegrationTests/` 2/2 pass.
    - next: /review
  timestamp: 2026-09-25T12:51:56.339659+00:00
depends_on:
- 01M39ZMNME683Y75PX48NQKTEN
position_column: doing
position_ordinal: '80'
title: 'R1: size the prompt-cache byte budget from the pool and give it to the fork'
---
## Why

The user decided on 2026-09-24: the prompt-cache limit is memory in BYTES, not a number of sessions, and an entry that does not fit in memory goes to disk. The fork removes `ExecutorPromptCacheStore.maximumRetainedSessions`. The budget comes from the Router, because several models can be resident together. Design: `generation-queue.md`, section 3.

## Fork dependency (done)

Fork tasks ^zcys2qw (public budget API) and ^mre55m3 (spill cost) are merged on the fork's `stable` branch at `ffac55d` (2026-09-25). The Router pin is `41e9f41`, which is 45 commits before `ffac55d` and does not have this API. Step 1 moves the pin.

## Fork API this task uses

Verified against `Libraries/MLXFoundationModels/MLXLanguageModel.swift` at `ffac55d`:

```swift
public static func configurePromptCache(memoryBudgetBytes: Int) async   // applies at once; a smaller budget spills before the call returns
public static func configurePromptCache(diskBudgetBytes: Int) async     // applies at once; a smaller budget deletes LRU files
public static var promptCacheUsage: (memoryBytes: Int, spillingBytes: Int, diskBytes: Int) { get async }
```

Fork defaults when the host sets nothing: memory = 25% of max(0, maxRecommendedWorkingSetSize - Memory.activeMemory) at first use; disk = 25% of the free space of the volume.

## Spill cost (fork task ^mre55m3, `generation-queue.md` section 3)

| Model | Context | Prefill s | Write + read s | File | Longest `evalLock` hold s |
|---|---|---|---|---|---|
| Qwen3-4B-4bit | 4k | 1.57 | 0.14 | 604 MB | 0.12 |
| Qwen3-4B-4bit | 32k | 13.1 | 1.35 | 4.8 GB | 1.19 |
| Qwen3.8-27B-mxfp4 | 4k | 5.0 | 0.07 | 422 MB | 0.05 |
| Qwen3.8-27B-mxfp4 | 32k | 53.0 | 0.30 | 2.3 GB | 0.22 |

- A spill and a restore cost much less than a prefill. A spill is better than a drop.
- A spill write holds MLX's process-wide `evalLock` for the whole write. The fork has one serial writer. Thus a large spill stops the evaluation of every other model for up to approximately 1.2 s.
- Each read came from a warm OS page cache. A read from a cold disk can be slower.

## What to do

1. Bump the fork pin to `ffac55d` or later: `Package.resolved` of the root package and of `IntegrationTests` (both follow the fork's `stable` branch; the files are gitignored, so run `swift package update mlx-swift-lm` in both and write the resolved revision in a comment). R2 ^cc2tezn and R3 ^ptev9yy also need this pin.
2. Compute the memory budget: `HostProfile.recommendedMaxWorkingSetSize` minus the sum of `PoolEntry.footprintBytes` (weights plus `acquiredChargeBytes`). `acquiredChargeBytes` is one KV estimate for each SLOT hold, not for each session (`ModelPool.acquireModel` charge and its release); many sessions share one hold, so there is no double count.
3. Call `configurePromptCache(memoryBudgetBytes:)` when a model loads, and again when a model loads or unloads (the pool insert and evict paths).
4. Count resident prompt-cache memory as `memoryBytes + spillingBytes`. An entry that is being written to disk stays in memory until the write ends, and the fork has one serial writer, so `spillingBytes` can stay high for some time.
5. Use the spill cost table above when you choose the budget. Write in a comment the `evalLock` stall that a spill of a large entry can cause for the other models.
6. Decide if the Router sets the disk budget (`configurePromptCache(diskBudgetBytes:)`) or keeps the fork default. Write the decision in a comment.
7. The store is process-wide. If more than one pool can exist in one process, write down how their budgets combine.
8. Write in the doc comment of `Footprint` (`Sizing/Footprint.swift`) that it does not size recurrent state (Mamba/SSM).

## Test precision note

On M5 GPUs, MLX computes float32 matmul in TF32 by default (`MLX_ENABLE_TF32`). The fork sets `MLX_ENABLE_TF32=0` only in its own `MLXLMTests` bundle (target `MLXTestPrecision`). If a Router test compares float32 outputs of two paths, it can need the same setting.

## Not in this task

- A directory for the cache files: the fork owns the spool folder (one for each process under the temporary directory; the folders of dead processes are deleted at first use). The Router gives no directory.
- A warm cache after a process restart: not done in any task. The user decided on 2026-09-24 that a cold cache after a restart is acceptable (`generation-queue.md`, section 3).

## Acceptance Criteria

- [x] A unit test of the budget computation, with 0, 1, and 2 resident models.
- [x] The budget is sent again after a load and after an unload (test with a recording double).
- [x] The pool sizing counts `memoryBytes + spillingBytes` (test with a double that reports spilling bytes).
- [x] A comment gives the disk-budget decision and the resolved fork revision (`ffac55d` or later).
- [x] An integration test (gated) with two resident models: weights plus caches stay within the pool budget.
- [x] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green on the new fork pin. #generation-queue #prompt-cache