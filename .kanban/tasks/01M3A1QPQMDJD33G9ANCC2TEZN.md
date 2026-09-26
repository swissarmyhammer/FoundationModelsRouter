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
- actor: claude-code
  id: 01m3cyvnznsgxk7pk0sv05xexh
  text: |-
    From the design task ^jdp02p (2026-09-25, `generation-queue.md` section 5): the item of the generation queue becomes one submission to Foundation (one whole SDK call), run by one worker task for each model (^a0ze9af, ^1psqdm9). What changes for R2:
    - The seam does not change. The per-session scope binding still happens in the per-session wrapper, inside its executor `respond`, around the inner executor call. The SDK calls that executor below the submission, so the binding is still on the task of the inner executor call.
    - ^1psqdm9 renames `QueuedLanguageModel` to `SessionLanguageModel` and removes the queue from it. If R2 lands first, the rename carries the binding with it. If R2 lands after ^1psqdm9, put the binding in `SessionLanguageModel.Executor.respond`.
    - ^a0ze9af (before ^1psqdm9) still runs each PASS as an item on the worker task. If R2 lands between ^a0ze9af and ^1psqdm9, the binding must go INSIDE the closure that the executor submits, because the worker task inherits no task-local (^a0ze9af step 3 says so).
    - Step 4 (release on close) is unchanged. A session that the pump drives still has one ULID for all of its submissions, so the key stays stable across submissions and continuations.
  timestamp: 2026-09-25T18:57:18.325076+00:00
- actor: claude-code
  id: 01m3evk4236mxvc3vymgfgk4nw
  text: |-
    Research (implement, 2026-09-26).

    Map of old names to current code:
    - "per-session queued wrapper (^8csj2hw)" = `SessionLanguageModel` (`Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`), state `SessionLanguageModelState`. The binding goes in `SessionLanguageModel.Executor.respond`, INSIDE the `pass` closure, around `innerRespond(request, channel)`. The pass closure is the body that a recording-handle wrapper submits to its pass queue, so the binding is on the task of the inner executor call on both paths.
    - `RoutedSessionActor.close()` is still in `Session/RoutedSessionActorForking.swift`. It still has `let terminalEvents = await mailbox.sweep(); guard !terminalEvents.isEmpty else { return }`. `turnLock`, `beginTurn/endTurn` are gone (^3qx0mpt); nothing in close() refers to them.
    - Forks: `backend.makeFork(tools:seededFrom:)` (^dpn2ytt) makes a new `MLXFoundationModelsSessionBackend` with a new wrapper; the child actor gets its own `childId`.
    - Step 1 (pin): skip. Root and `IntegrationTests` `Package.resolved` both pin mlx-swift-lm `ffac55d4e9e0f75d30347c561cea042b674be831` (R1 ^tv2yt7s).
    - Gated test: `secondTurnReusesFirstTurnsKVCache` is now `secondAnswerReusesFirstAnswersKVCache` (`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`).

    Seam for the session id: the backend is made before the session actor exists (container `makeSession`, `makeFork`, `replacingTranscript`), and none of them know the session id. The actor already installs its pass observer on each backend it adopts (`observeGenerationPasses(of:)`, called in `init` and in the `didSet` of `backend`). The session installs its prompt-cache session id at the same two points. Consequences:
    - A fork's actor installs the fork ULID on the fork backend, so a fork and its parent have two keys.
    - A compaction, a repetition rebuild and discovery priming replace `backend` through `replacingTranscript`; the `didSet` installs the same session ULID, so the key stays.
    - The summarizer backends (own-model tier: `backend.replacingTranscript([])` that is never assigned to `backend`; flash tier: `profile.flash.container.makeSession`) never get an installation, so they keep the fork's default rule (nil scope). They do NOT share the key of the session. R3 ^ptev9yy makes them `.uncached`.
    - I did NOT put the id into `replacingTranscript`: the own-model summarizer is built with `replacingTranscript`, so it would then write into the cache of the session.
    - All backends of one session run over one raw model (`replacingTranscript` keeps `model`), so "each model the session used" is the model of the current backend. The release goes through the current backend.
    - A restored session reuses its persisted ULID, so it gets the same key.
  timestamp: 2026-09-26T12:38:40.963863+00:00
- actor: claude-code
  id: 01m3ewgfp6whk3ex5f998nhdef
  text: |-
    Implementation landed (2026-09-26). Decisions and reasons:

    - Binding: `SessionLanguageModelState.withPromptCacheScope(_:)` binds `MLXLanguageModel.$promptCacheScope.withValue(.session(id))` around `innerRespond(request, channel)`, INSIDE the `pass` closure of `SessionLanguageModel.Executor.respond`. So the binding is on the task of the inner executor call, also when a recording-handle wrapper submits the pass to its pass queue. A wrapper with no installed id binds nothing (fork default rule). The recording-handle wrappers (`LoadedLLMContainer.languageModel`) and the summarizer backends never get an id.
    - Where the id comes from: the session installs it on each backend it adopts. New `RoutedSessionActor.adopt(_:)` (new file `Session/RoutedSessionActorPromptCache.swift`) calls the existing `observeGenerationPasses(of:)` and the new `SessionPromptCacheScoping.scopePromptCache(toSession:)`. `init` and the `didSet` of `backend` now call `adopt(_:)`. The key is `id.description` (`promptCacheSessionID`).
    - No new lock: the id sits in the SAME guarded slot as the pass observer (`SessionLanguageModelState.installation`, a struct with both fields, formerly `installedPassObserver`). No wait, no semaphore, no session lock.
    - Release: `close()` calls `releasePromptCache()` after `mailbox.sweep()` and BEFORE `guard !terminalEvents.isEmpty`. It goes through the current backend: `MLXFoundationModelsSessionBackend.releasePromptCache(ofSession:)` casts its raw model to the new internal protocol `SessionPromptCacheReleasing` (`MLXLanguageModel` conforms with no code, because its `releasePromptCache(sessionID:)` matches). All backends of one session share one raw model (`replacingTranscript` keeps `model`), so this is "each model the session used".
    - Doc comment of `close()` states the LRU/disk-budget limit for a session dropped without close (step 6), and that a pass that ends after close can write the entry again under the same limits. `RoutedSession.close()` public doc says the close releases the cache and a fork close does not release the parent.
    - Protocols are new and internal: `SessionPromptCacheReleasing` (raw model) and `SessionPromptCacheScoping` (backend), in `Concurrency/SessionPromptCache.swift`. They follow the `GenerationPassReporting` pattern; a stub backend does not conform and its session keys no cache.
    - Test seam: `PromptCacheScopeRecordingModel` (test helper) is a scripted `LanguageModel` behind the production backend and a real `LanguageModelSession`; its executor records `MLXLanguageModel.promptCacheScope` for each pass, and it conforms to `SessionPromptCacheReleasing` to record releases.
    - Extra real-model proof (gated): `LanguageModelSessionBackendIntegrationTests.sessionKeyedCacheIsReusedUntilItsRelease`. Answer 2 under a `.session` id reuses the cache; after `releasePromptCache(ofSession:)`, answer 3 reuses 0 tokens. I checked that it fails when the binding is removed (temporary change, reverted): answer 3 then reused 75 tokens, because the fork keyed the pass by the first entry and the release removed nothing. So the binding reaches the fork executor.
    - Out of scope, for R3 ^ptev9yy: the summarizer backends still run with a nil scope (first-entry rule). They do not share the key of the session.
    - `ARCHITECTURE.md` does not exist; nothing to update.
  timestamp: 2026-09-26T12:54:43.142386+00:00
- actor: claude-code
  id: 01m3ewgp2y40d7ahmphzqmazs6
  text: |-
    ### implement — changed
    - evidence: 4 new files — Sources/FoundationModelsRouter/Concurrency/SessionPromptCache.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorPromptCache.swift, Tests/FoundationModelsRouterTests/SessionPromptCacheKeyTests.swift, Tests/FoundationModelsRouterTests/Helpers/PromptCacheScopeRecordingModel.swift; 7 changed — Concurrency/SessionLanguageModel.swift, Resolution/LiveModelLoader.swift, Session/RoutedSession.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorPassReports.swift, IntegrationTests/.../LanguageModelSessionBackendTests.swift. `swift test`: 1473 + 15 + 19 = 1507 passed (was 1502; +5 new), 2 known issues that existed before. Clean build in a new scratch path (`swift build --build-tests`): zero compiler warnings (only the known `missing creator for mutated node` line). Gated real model: `swift test --package-path IntegrationTests --filter "secondAnswerReusesFirstAnswersKVCache|sessionKeyedCacheIsReusedUntilItsRelease"`: 2 passed.
    - next: review
  timestamp: 2026-09-26T12:54:49.694279+00:00
depends_on:
- 01M39ZNAJWMVZ291SCH8CSJ2HW
position_column: doing
position_ordinal: '80'
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

- [x] A fork and its parent use two different keys (test with a model that records the key of each pass). <!-- proven by SessionPromptCacheKeyTests.aForkAndItsParentUseTwoKeys -->
- [x] A closed session releases its key on each model it used. The close of a fork does not release the key of its open parent. <!-- proven by SessionPromptCacheKeyTests.aClosedSessionReleasesItsKey and SessionPromptCacheKeyTests.closingAForkDoesNotReleaseItsParentsKey; real model: LanguageModelSessionBackendIntegrationTests.sessionKeyedCacheIsReusedUntilItsRelease -->
- [x] A compaction keeps the key of the session (no new key in the store). <!-- proven by SessionPromptCacheKeyTests.aCompactionKeepsTheKeyOfTheSession -->
- [x] A session closed with no mailbox events still releases its key. <!-- proven by SessionPromptCacheKeyTests.aSessionClosedWithNoMailboxEventsReleasesItsKey -->
- [x] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green. <!-- the test is now named secondAnswerReusesFirstAnswersKVCache (^f33q8gw); green on 2026-09-26 on this machine, with the real model --> #generation-queue #prompt-cache