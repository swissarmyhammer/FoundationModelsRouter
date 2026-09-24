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
depends_on:
- 01M39ZPCNPZCG3RPG9Q6WQKETZ
- 01M3A1QPQMDJD33G9ANCC2TEZN
position_column: todo
position_ordinal: 8a80
title: 'R3: summarizer calls keep no prompt cache'
---
## Why

Each compaction summarizer call runs on a new backend (`performAutoCompaction` and `ownModelSummarizerSlot` in `Session/RoutedSessionActorCompaction.swift`), so each call adds a new key to the fork's prompt-cache store and pushes out the cache of a real session. Design: `generation-queue.md`, section 3.

## External dependency (tag `needs-fork`)

Fork task ^2mk47nr on the mlx-swift-lm board (the task-local key). Do not start until it is merged on the fork's `stable` branch and the Router pin includes it (R2 ^cc2tezn bumps the pin). Then remove the `needs-fork` tag.

## The seam

The key is bound in the executor `respond` of the per-session queued wrapper (^8csj2hw), which R2 ^cc2tezn makes bind `.session(<ULID>)`. This task adds the `.none` case to the same binding. Thus this task depends on R2. A binding in the compaction code, above `LanguageModelSession`, does not reach the executor.

## What to do

1. Give the per-session wrapper state a way to say "this backend keeps no prompt cache", set when the backend is made for a summarizer. Its executor then binds `MLXLanguageModel.$promptCacheScope` to `.none`.
2. Make each summarizer backend with that setting: the flash tier and the own-model tier, on every compaction path (turn start, tool-result boundary, ceiling stop, overflow retry, and the caller `compact`).
3. Do this with ^6wqketz, which puts each summarizer call on the queue of its own container.

## Acceptance Criteria

- [ ] A compaction adds no key to the store: the key count and the byte total (`promptCacheUsage`) are the same before and after (test).
- [ ] The next pass of the compacted session still reuses its own cache (gated test).
- [ ] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green. #generation-queue #prompt-cache #needs-fork