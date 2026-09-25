---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a1s05gdctdh8wkbkkv6kp2
  text: '2026-09-24: the FoundationModelsAgents session accepted the task-local key, and the plan file changed. Fork F6 is now "a public task-local cache key that the host sets" (`.session(String)`, `.none`, fallback to the first entry id). The external dependencies of this task are thus F5 (release) and F6 (task-local), and no separate proposal task exists. The holder count is only the fallback if the mlx session refuses F6.'
  timestamp: 2026-09-24T15:50:32.880445+00:00
- actor: claude-code
  id: 01m3a1ycjqeyeb0224x4pgbbbb
  text: 'Fork dependencies (mlx-swift-lm board, 2026-09-24): ^2mk47nr (task-local, no dependency, can land first) and ^zcys2qw (release). The mlx session verified that the task-local reaches sessionCacheKey: Executor.respond -> withTaskCancellationHandler -> $drainCoordinator.withValue -> runRespond -> sessionCacheKey, all on one task. LIMIT: the binding does NOT reach the executor through LanguageModelSession, because the SDK can run the executor on another task. The wrapper must bind it inside its own executor respond and call the inner executor directly (as RecordingLanguageModelState.makePassthrough does). API: `public enum PromptCacheScope { case session(String); case none }`, `@TaskLocal public static var promptCacheScope: PromptCacheScope?` (nil = first-entry-id rule), `public func releasePromptCache(sessionID: String) async` (memory + spilling + disk for this model id; no-op if unknown). The release id is the same string the wrapper binds. The holder count is not necessary.'
  timestamp: 2026-09-24T15:53:29.431805+00:00
depends_on:
- 01M39ZNAJWMVZ291SCH8CSJ2HW
position_column: todo
position_ordinal: '8980'
title: 'R2: key the prompt cache by the Router session id, and release it when the session closes'
---
## Why

Without a scope, the fork keys the cache by `(modelID, id of the first transcript entry)`. Results:

- A fork has the first entry of its parent, so the two share one key and take the one entry from each other.
- A compaction or repetition rebuild that drops the first entry orphans the old key.
- The store never learns that a session ended.

Decision (accepted by the FoundationModelsAgents and mlx-swift-lm sessions, 2026-09-24): the Router gives each session its own key through the fork's task-local, and releases it on close. No count of holders is necessary. Design: `generation-queue.md`, sections 2 and 3.

## Fork dependency (done)

Fork tasks ^2mk47nr (the task-local key) and ^zcys2qw (the release) are merged on the fork's `stable` branch at `ffac55d` (2026-09-25).

## Fork API this task uses

Verified against `MLXLanguageModel.swift` and `MLXLanguageModel+PromptCacheScope.swift` at `ffac55d`:

```swift
public enum PromptCacheScope: Sendable, Hashable { case session(String); case uncached }
@TaskLocal public static var promptCacheScope: PromptCacheScope?   // nil = first-entry-id rule
public func releasePromptCache(sessionID: String) async            // memory + spilling + disk; no-op if unknown
```

## What to do

1. Bump the fork pin to `ffac55d` or later in the root package and in `IntegrationTests` (`swift package update mlx-swift-lm` in both; write the resolved revision in a comment). Skip this step if R1 ^tv2yt7s already moved the pin to `ffac55d` or later.
2. In the executor `respond` of the per-session queued wrapper (^8csj2hw), bind `MLXLanguageModel.$promptCacheScope` to `.session(<the session ULID>)` around the call of the inner executor, on the same task, on every pass. LIMIT (verified by the mlx session): the binding reaches the fork's executor only when the host calls `Executor.respond` directly on the same task. A binding made on the session actor, above `LanguageModelSession`, does not reach it, because the SDK can run the executor on another task.
3. The per-session wrapper state of ^8csj2hw thus carries the session ULID. A fork gets the ULID of the fork, not of its parent. Thus a fork has its own key, and no count of holders is necessary.
4. `RoutedSessionActor.close()` (`Session/RoutedSessionActorForking.swift`) calls `releasePromptCache(sessionID:)` with the same ULID string, on each model that the session used. Put the call BEFORE the `guard !terminalEvents.isEmpty else { return }` early return, or the release is skipped for most sessions.
5. A compaction that drops the first entry keeps the key, because the key is the session ULID. There is nothing to release on a compaction.
6. A session that is dropped without `close()` is still limited: the fork's byte LRU and disk budget remove it later. Write this in the doc comment of `close()`.

## Acceptance Criteria

- [ ] A fork and its parent use two different keys (test with a model that records the key of each pass).
- [ ] A closed session releases its key on each model it used. The close of a fork does not release the key of its open parent.
- [ ] A compaction keeps the key of the session (no new key in the store).
- [ ] A session closed with no mailbox events still releases its key.
- [ ] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green. #generation-queue #prompt-cache