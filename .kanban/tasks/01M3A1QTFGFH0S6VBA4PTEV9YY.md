---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a1s2x25ppqrbbpvktcqk81
  text: '2026-09-24: fork F6 is now the task-local cache key. This task binds `.none` around each summarizer call. It must bind the key where the summarizer backend calls its executor: in the per-session queue wrapper of ^8csj2hw (R2 ^cc2tezn), or in a summarizer-specific wrapper. It must not bind the key in the compaction code above the SDK call, because a task-local there reaches the executor only through the SDK''s own tasks.'
  timestamp: 2026-09-24T15:50:35.682561+00:00
- actor: claude-code
  id: 01m3a1yeyq6v1ex3s1hnxaf9qk
  text: 'Fork dependency (mlx-swift-lm board, 2026-09-24): ^2mk47nr. Bind `MLXLanguageModel.$promptCacheScope` to `.none` inside the wrapper''s executor respond for each summarizer backend. Then the inner executor keeps no entry.'
  timestamp: 2026-09-24T15:53:31.863737+00:00
- actor: claude-code
  id: 01m3c6mzfn76hp8xn6cr79k3t8
  text: '2026-09-25: the two comments of 2026-09-24 that say `.none` are out of date. The fork case is `.uncached` (fork `ffac55d`). `.none` resolves to `Optional.none` and adds a key. Use the description.'
  timestamp: 2026-09-25T11:54:12.853718+00:00
- actor: claude-code
  id: 01m3cywgm7jbneyz5gkr553exr
  text: |-
    From the design task ^jdp02p (2026-09-25, `generation-queue.md` section 5): what changes for R3.
    - The seam does not change: the `.uncached` binding goes in the executor `respond` of the per-session wrapper, next to the R2 binding. ^1psqdm9 renames the wrapper `SessionLanguageModel`; if R3 lands after it, use the new name.
    - A summarizer call is one submission on the queue of the container that runs it (^1psqdm9 step 3, ^6wqketz). The binding is below that submission, in the executor, so it still reaches the fork.
    - The compaction paths change place: the proactive compaction and the compaction after a yield, a ceiling stop or an overflow happen at the pump, between two submissions (^3qx0mpt). Step 2 of this task ("every compaction path") must cover the pump path; the list of paths is otherwise the same.
  timestamp: 2026-09-25T18:57:45.607454+00:00
depends_on:
- 01M39ZPCNPZCG3RPG9Q6WQKETZ
- 01M3A1QPQMDJD33G9ANCC2TEZN
position_column: todo
position_ordinal: 8a80
title: 'R3: summarizer calls keep no prompt cache'
---
## Why

Each compaction summarizer call runs on a new backend (`performAutoCompaction` and `ownModelSummarizerSlot` in `Session/RoutedSessionActorCompaction.swift`), so each call adds a new key to the fork's prompt-cache store and pushes out the cache of a real session. Design: `generation-queue.md`, section 3.

## Fork dependency (done)

Fork task ^2mk47nr (the task-local key) is merged on the fork's `stable` branch at `ffac55d` (2026-09-25). The Router pin must be `ffac55d` or later (R1 ^tv2yt7s or R2 ^cc2tezn moves it).

## The case name: `.uncached`, NOT `.none`

The fork case is `MLXLanguageModel.PromptCacheScope.uncached` (verified in `MLXLanguageModel+PromptCacheScope.swift` at `ffac55d`). Do not write `.none`: the task-local type is `PromptCacheScope?`, so `.none` resolves to `Optional.none` (no scope). The executor then uses the first-entry-id rule and silently adds a key.

## The seam

The key is bound in the executor `respond` of the per-session queued wrapper (^8csj2hw), which R2 ^cc2tezn makes bind `.session(<ULID>)`. This task adds the `.uncached` case to the same binding. Thus this task depends on R2. A binding in the compaction code, above `LanguageModelSession`, does not reach the executor: the binding reaches the fork's executor only when the host calls `Executor.respond` directly on the same task that binds it.

## What to do

1. Give the per-session wrapper state a way to say "this backend keeps no prompt cache", set when the backend is made for a summarizer. Its executor then calls the inner `Executor.respond` inside `MLXLanguageModel.$promptCacheScope.withValue(.uncached) { ... }`, on the same task.
2. Make each summarizer backend with that setting: the flash tier and the own-model tier, on every compaction path (turn start, tool-result boundary, ceiling stop, overflow retry, and the caller `compact`).
3. Do this with ^6wqketz, which puts each summarizer call on the queue of its own container.

## Acceptance Criteria

- [ ] A compaction adds no key to the store: the key count and the byte total (`promptCacheUsage`) are the same before and after (test).
- [ ] A test fails if the binding is `Optional.none` in place of `.uncached`.
- [ ] The next pass of the compacted session still reuses its own cache (gated test).
- [ ] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green. #generation-queue #prompt-cache