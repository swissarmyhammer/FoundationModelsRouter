---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: Wire cross-turn KV cache in MLXLanguageModel.Executor (swissarmyhammer/mlx-swift-lm fork)
---
## What

The `MLXLanguageModel.Executor` currently passes `nil` for `cache:` to every `generate()` call, allocating a fresh `[KVCache]` per turn and re-processing the entire transcript from token 0 every time. The underlying `KVCache.offset` mechanism is fully functional — delta tokens placed at offset N get correct RoPE embeddings and attend to all prior-turn context via the causal mask. The fix is to persist the cache across turns within a session and pass only the delta tokens (new since last turn) to each generate call.

All changes are in `swissarmyhammer/mlx-swift-lm`, branch `mlx-foundationmodels`. After the branch is updated, bump the pinned revision in `FoundationModelsRouter/Package.resolved`.

### Changes in the fork

**New file `Libraries/MLXFoundationModels/ExecutorCacheStore.swift`:**
```swift
actor ExecutorCacheStore {
    struct Entry {
        var cache: [any KVCache]
        var processedTokenCount: Int
    }
    private var sessions: [String: Entry] = [:]
    
    func entry(forSessionKey key: String, model: any LanguageModel) -> Entry {
        if let existing = sessions[key] { return existing }
        let fresh = Entry(cache: model.newCache(parameters: nil), processedTokenCount: 0)
        sessions[key] = fresh
        return fresh
    }
    
    func update(key: String, cache: [any KVCache], processedTokenCount: Int) {
        sessions[key] = Entry(cache: cache, processedTokenCount: processedTokenCount)
    }
    
    func evict(key: String) { sessions.removeValue(forKey: key) }
}
```

Add a `private static let cacheStore = ExecutorCacheStore()` to `MLXLanguageModel` (or to `ModelCache`) so it is process-global and keyed by session.

**Session key:** `request.transcript.entries.first?.id ?? UUID().uuidString` — the first transcript entry's ID is stable for the entire life of a `LanguageModelSession`, making it a reliable per-session key without requiring a session-level ID on the request struct.

**`Executor.respond()` before dispatching to generation helpers:**
```swift
// 1. Tokenize full transcript → allTokens
// 2. Look up (or allocate) the session's cache entry
let sessionKey = request.transcript.entries.first?.id ?? UUID().uuidString
let entry = await Self.cacheStore.entry(forSessionKey: sessionKey, model: context.model)
let alreadyCached = min(entry.processedTokenCount, allTokens.count)
let deltaTokens = Array(allTokens[alreadyCached...])
// 3. Build deltaInput from deltaTokens only
// 4. Pass entry.cache + deltaInput to helpers
```

**`runUnconstrained`, `runReasoning`, `runGuidedGeneration`:** add `cache: [any KVCache]` parameter, forward to `generate(input:cache:parameters:context:)`.

**After generation completes** in each helper: write back `await Self.cacheStore.update(key: sessionKey, cache: cache, processedTokenCount: allTokens.count)`.

**Fix `cachedTokenCount: 0`** — currently hardcoded at 4 call sites inside `Executor.respond()`. Replace with `alreadyCached` at each site.

**Cache eviction:** hook `MLXLanguageModel.evict()` to also call `await Self.cacheStore.evict(key:)` for any sessions associated with that model ID.

### Router changes after fork update

- Bump `Package.resolved` to the new commit on `mlx-foundationmodels`
- No production `Sources/` changes needed — the caching is entirely inside the executor

## Acceptance Criteria
- [ ] `ExecutorCacheStore` actor exists in the fork
- [ ] `Executor.respond()` derives a session key from the first transcript entry ID
- [ ] Delta-token slicing: only tokens beyond `processedTokenCount` are passed to `generate()`
- [ ] `cachedTokenCount` in `.updateUsage` events reflects actual cached token count (not hardcoded `0`)
- [ ] `Package.resolved` in `FoundationModelsRouter` is updated to the new fork commit
- [ ] Integration tests pass (covered by task "Prove multi-turn conversation state and KV cache usage")

## Tests
- [ ] See task "Prove multi-turn conversation state and KV cache usage in router sessions" — `cachedTokenCount > 0` on turn 2+ is the proof
- [ ] Fork's own unit tests pass: `swift test` in the fork repo

## Workflow
- Work in the fork repo: `cd ~/github/swissarmyhammer/mlx-swift-lm` (or wherever it is checked out), branch `mlx-foundationmodels`
- `/tdd` — write a test in the fork asserting `cachedTokenCount > 0` on second turn, watch it fail, implement `ExecutorCacheStore`, watch it pass
- Commit to the fork, then bump `Package.resolved` in this repo