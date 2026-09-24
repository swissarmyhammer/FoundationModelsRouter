---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a1kh1xmc14sxt9kxzjsp6x
  text: '2026-09-24: scope change. The user wants the KV prompt cache on DISK, not only a larger limit in memory. I asked the mlx-swift-lm session (mlx-swift-lm-2f) to plan a disk tier for ExecutorPromptCacheStore on its board: write at eviction, read back on a miss, keep LMOutput.State in the entry (MLXLMCommon savePromptCache/loadPromptCacheSnapshot, KVCache.swift:1957/:2033), a disk limit, and a delete for each session. Do not start this task until that session replies with task ids and an API. Then re-scope this task to the fork items it owns, and add Router tasks for: the directory wiring (next to the recording directory of each session), sizing from the pool budget, delete at session end, and a warm restore after a process restart.'
  timestamp: 2026-09-24T15:47:33.565146+00:00
- actor: claude-code
  id: 01m3a1kse7e0dfbazetg5qryge
  text: 'User requirement (2026-09-24): no hard-coded session limit. Remove `maximumRetainedSessions = 4` and do not put another fixed count in its place. The memory tier is limited by bytes. The host sets the limit (the Router sizes it from the pool budget). An entry that goes out of memory goes to the disk tier; it is not dropped. I sent this to mlx-swift-lm-2f.'
  timestamp: 2026-09-24T15:47:42.151317+00:00
- actor: claude-code
  id: 01m3a1qzgt3vcp04jj5bwatvk3
  text: Folded on 2026-09-24 into the plan from the FoundationModelsAgents session. The limit setting goes to R1; the fork key and the release go to R2; the summarizer cache goes to R3 (tag prompt-cache). The interleave test with more sessions than the budget holds goes to fork task F3. The fork pin bump and `secondTurnReusesFirstTurnsKVCache` go with each R task that needs a new fork API. This task is archived.
  timestamp: 2026-09-24T15:49:59.450371+00:00
depends_on:
- 01M39ZMNME683Y75PX48NQKTEN
position_column: todo
position_ordinal: '8580'
title: 'mlx-swift-lm fork: keep the prompt cache useful when passes of many sessions interleave'
---
## Why

The fork keeps one KV prompt cache for each session in `ExecutorPromptCacheStore.shared` (`.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/ExecutorPromptCache.swift:55-111`). Facts from the code:

- Key: `(modelID, id of the first transcript entry)` (`MLXLanguageModel.swift:857-862`).
- Limit: `maximumRetainedSessions = 4`, least recently used out first (`ExecutorPromptCache.swift:66`, `:93-95`).
- A check-out REMOVES the entry. Two passes with one key at the same time thus do not corrupt the cache; the second starts cold. A key collision is a speed problem, not a correctness problem.

With passes of more than 4 sessions interleaved, the round-robin removes a cache before its session comes back. Each pass then does a full prefill. This was true before for turns; per-pass order makes it more frequent.

Not verified: a fork copies the transcript of its parent (`LiveModelLoader.swift:528-537`), so it probably has the same first entry id and the same key. Each summarizer backend is a new session with a new first entry, so each call adds a cache that pushes out a real session.

## What to do (in the fork, where the cache lives)

1. Make the limit a setting. Size it from the memory budget of the pool, and count the caches in `Sizing/Footprint.swift` in this repo.
2. Give a fork a cache key of its own. Measure first: verify that a fork and its parent share a key now.
3. Keep no cache for a summarizer call (a setting on the request or on the backend).
4. Add a test that interleaves N > limit sessions and measures the prefill tokens of each pass (`reusedTokenCount`).
5. Bump the fork pin in `Package.swift`/`Package.resolved` here.

## Acceptance Criteria

- [ ] Fork test: N sessions with N above the old limit and within the new limit interleave passes; each pass after the first reuses its prefix.
- [ ] A fork and its parent have different keys (test), or a comment on this task shows they did not collide.
- [ ] A summarizer call leaves no entry in the store.
- [ ] `secondTurnReusesFirstTurnsKVCache` in this repo stays green. #generation-queue