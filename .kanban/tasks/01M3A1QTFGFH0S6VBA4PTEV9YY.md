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
- actor: claude-code
  id: 01m3ex76zq6w5tqgctytexpwyr
  text: |-
    Research (2026-09-26):
    - The Router pin of the fork is `ffac55d` (Package.resolved). The case is `MLXLanguageModel.PromptCacheScope.uncached`. The task-local type is `PromptCacheScope?`.
    - All compaction paths go through one seam. `compactOwnModel` (the caller `compact`, run by the pump) and `performAutoCompaction` (the proactive compaction at the pump, the tool-result yield in `RoutedSessionActorCompactionYield`, the ceiling stop and the overflow retry in `RoutedSessionActorAnswerExecution`) all call `runCompaction`. `runCompaction` makes each tier slot with `BackendSummarizerTier.slot(for:)`, and each call runs in `BackendCompactionSummarizer.summarize`, on `backend.replacingTranscript(Transcript(entries: []))`. This is true for the flash tier (`profile.flash.container.makeSession`) and for the own-model tier (the live backend).
    - `replacingTranscript` makes a new backend with a new `SessionLanguageModel` wrapper and a new `SessionLanguageModelState`. That state has no scope, so today each summarizer pass binds nothing and the fork keys it by the first transcript entry.
    - The fork has no public key count. `ExecutorPromptCacheStore.retainedSessionCount` is internal ("Read by tests"). `MLXLanguageModel.promptCacheUsage` gives the byte totals only.
    - The real models are on this machine (128 GB; `Qwen2.5-3B-Instruct-4bit` and `Muse-Glimmer-30B-mxfp4` are in the Hub cache), so the gated test can run.

    Decision: the state keeps one `MLXLanguageModel.PromptCacheScope?` in place of the session id string. `scopePromptCache(toSession:)` sets `.session(id)`. A new `keepNoPromptCache()` (on `SessionLanguageModelState` and on `SessionPromptCacheScoping`) sets `.uncached`. `BackendCompactionSummarizer` calls it on the blank backend before its one call. The executor `respond` binds the stored scope, on the task of the inner executor call, as R2 does.
  timestamp: 2026-09-26T13:07:07.895011+00:00
- actor: claude-code
  id: 01m3exzczex1rc0k9ebz4t9zfm
  text: |-
    Implementation (2026-09-26):
    - `SessionLanguageModelState` keeps one `MLXLanguageModel.PromptCacheScope?` in place of the session id string. `scopePromptCache(toSession:)` sets `.session(id)`. The new `keepNoPromptCache()` sets `.uncached`. `withPromptCacheScope(_:)` binds the stored scope on the task of the inner executor call, as R2 does. `SessionPromptCacheScoping` has the new requirement `keepNoPromptCache()`, and `MLXFoundationModelsSessionBackend` forwards it to its wrapper state.
    - `BackendCompactionSummarizer.summarize` calls `keepNoPromptCache()` on the blank backend before its one call. All compaction paths (the caller `compact`, the proactive compaction at the pump, the tool-result yield, the ceiling stop, the overflow retry) and both tiers (flash, own model) make their calls there, so one seam covers them.
    - TDD: `SummarizerPromptCacheTests` failed first on the scope and key assertions, then passed. The recording model helper now records the first transcript entry id (the key the fork gives a pass with no scope) and can report usage, so the auto compaction starts at the pump.
    - Mutation check: `keepNoPromptCache()` with `.none` makes both unit tests and the gated key test fail. Restored to `.uncached`.
    - Gated (real Qwen2.5-3B, this machine): `SummarizerPromptCacheIntegrationTests` 2/2 passed; `secondAnswerReusesFirstAnswersKVCache` (the old `secondTurnReusesFirstTurnsKVCache`, renamed by ^f33q8gw) and `sessionKeyedCacheIsReusedUntilItsRelease` passed. The gated suite reads the key count through `@testable import MLXFoundationModels` (`ExecutorPromptCacheStore.retainedSessionCount`), because the fork has no public key count.
    - Note: other sessions added board files during this work (tasks 01M3EX8BQ6033ZYFJNSN3RCZ0X, 01M3EXEEDTD9DTP571SQHF29TG, tag `dead-code`). This task did not make or change them.
  timestamp: 2026-09-26T13:20:20.462793+00:00
- actor: claude-code
  id: 01m3exzm7qkd5vcb0xtzep5j25
  text: |-
    ### implement — changed
    - evidence: 8 files changed or added — Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift, Sources/FoundationModelsRouter/Concurrency/SessionPromptCache.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorPromptCache.swift, Tests/FoundationModelsRouterTests/Helpers/PromptCacheScopeRecordingModel.swift, Tests/FoundationModelsRouterTests/SummarizerPromptCacheTests.swift (new), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SummarizerPromptCacheIntegrationTests.swift (new). `swift test`: 1475 + 15 + 19 = 1509 passed (1507 before, plus 2 new), 0 failed. Full first-party recompile: 0 compiler warnings (only the known mlx-swift_Cmlx.bundle note). Gated: SummarizerPromptCacheIntegrationTests 2/2, secondAnswerReusesFirstAnswersKVCache and sessionKeyedCacheIsReusedUntilItsRelease 2/2 passed. Acceptance criteria 4/4 checked.
    - next: review
  timestamp: 2026-09-26T13:20:27.895222+00:00
- actor: claude-code
  id: 01m3eycfrqzcfp3jtsgx872968
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 1 finding (1 confirmed, 0 refuted) — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SummarizerPromptCacheIntegrationTests.swift:30 (code-hygiene/idioms-swift preferLazyMap).
    - next: Use lazy.map before min() at that line, and remove the same cause from the whole file. Then run the review again.
  timestamp: 2026-09-26T13:27:29.303375+00:00
- actor: claude-code
  id: 01m3eyfgz3d9gbx7jn5a999q3x
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files (summarizer backends bind .uncached; unit and gated tests)
    - test: green — swift test, 1509 passed (1475+15+19), 0 failed, 0 skipped; 5 cache and compaction suites 3 extra runs clean; gated real-model tests passed (implementer run)
    - commit: eccc9b1
    - review: findings — IntegrationTests/.../SummarizerPromptCacheIntegrationTests.swift:30
  timestamp: 2026-09-26T13:29:08.835449+00:00
- actor: claude-code
  id: 01m3eyj5vy2csvar6h7mwev3f1
  text: 'Fix of the review finding (2026-09-26): `fillingPrompt` in `SummarizerPromptCacheIntegrationTests.swift` now uses `(1...fillingFactCount).lazy.map { ... }.joined(separator: " ")`. That was the only `map`, `filter`, or `compactMap` call in the file. `SummarizerPromptCacheTests.swift` has no such call, so it did not change. The prompt text is the same, so the gated tests feed the same tokens.'
  timestamp: 2026-09-26T13:30:35.774855+00:00
- actor: claude-code
  id: 01m3eyj86jn691v9yz0k7s54vf
  text: |-
    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SummarizerPromptCacheIntegrationTests.swift. `swift build --build-tests` in IntegrationTests/: pass (only the known mlx-swift_Cmlx.bundle note). Gated `swift test --filter SummarizerPromptCacheIntegrationTests` (real Qwen2.5-3B): 2/2 passed. Root `swift test`: 1475 + 15 + 19 = 1509 passed, 0 failed (2 known issues from `withKnownIssue` tests that were there before). Review finding 1/1 checked.
    - next: review
  timestamp: 2026-09-26T13:30:38.162526+00:00
depends_on:
- 01M39ZPCNPZCG3RPG9Q6WQKETZ
- 01M3A1QPQMDJD33G9ANCC2TEZN
position_column: doing
position_ordinal: '80'
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

- [x] A compaction adds no key to the store: the key count and the byte total (`promptCacheUsage`) are the same before and after (test). <!-- Gated: SummarizerPromptCacheIntegrationTests.aCompactionAddsNoKeyToThePromptCache (real Qwen2.5-3B; key count = ExecutorPromptCacheStore.retainedSessionCount, bytes = MLXLanguageModel.promptCacheUsage), passed 2026-09-26. Unit: SummarizerPromptCacheTests.ownModelSummarizerOfACallerCompactionAddsNoKey and flashSummarizerOfAnAutomaticCompactionAddsNoKey (PromptCacheScopeLog.storeKeys). -->
- [x] A test fails if the binding is `Optional.none` in place of `.uncached`. <!-- SummarizerPromptCacheTests (both tests) and SummarizerPromptCacheIntegrationTests.aCompactionAddsNoKeyToThePromptCache. Proved by mutation on 2026-09-26: keepNoPromptCache() set to `.none` made all three fail; restored to `.uncached`. -->
- [x] The next pass of the compacted session still reuses its own cache (gated test). <!-- SummarizerPromptCacheIntegrationTests.theNextAnswerAfterACompactionReusesItsOwnCache: cachedTokenCount of the answer after the compaction >= the token count of the instructions. Passed 2026-09-26. -->
- [x] `secondTurnReusesFirstTurnsKVCache` (`IntegrationTests/.../LanguageModelSessionBackendTests.swift`) stays green. <!-- The test is now named secondAnswerReusesFirstAnswersKVCache (^f33q8gw rename). Passed 2026-09-26, with sessionKeyedCacheIsReusedUntilItsRelease (R2). --> #generation-queue #prompt-cache

## Review Findings (2026-09-26 08:25)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SummarizerPromptCacheIntegrationTests.swift:30` `code-hygiene/idioms-swift` — preferLazyMap: Prefer lazy.map over map before single-pass operations like min().
