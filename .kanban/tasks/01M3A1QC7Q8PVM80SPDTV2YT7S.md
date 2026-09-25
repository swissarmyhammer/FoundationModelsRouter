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
depends_on:
- 01M39ZMNME683Y75PX48NQKTEN
position_column: todo
position_ordinal: '8880'
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

- [ ] A unit test of the budget computation, with 0, 1, and 2 resident models.
- [ ] The budget is sent again after a load and after an unload (test with a recording double).
- [ ] The pool sizing counts `memoryBytes + spillingBytes` (test with a double that reports spilling bytes).
- [ ] A comment gives the disk-budget decision and the resolved fork revision (`ffac55d` or later).
- [ ] An integration test (gated) with two resident models: weights plus caches stay within the pool budget.
- [ ] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green on the new fork pin. #generation-queue #prompt-cache