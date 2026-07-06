---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Wire cross-turn KV cache persistence in MLXLanguageModel.Executor
---
## Context

`MLXLanguageModel.Executor.respond()` currently calls `generate(input:parameters:context:)` without a `cache:` argument on every turn, so `TokenIterator.init` always allocates a fresh `[KVCache]` via `model.newCache(parameters:)`. Every turn re-processes the full transcript from token 0. This is the uncached path that was identified as unacceptable.

## Root cause

`Executor` is a `struct` with only `let modelID: String` — no mutable state. There is no session ID in `LanguageModelExecutorGenerationRequest` (it has `request.id: UUID` per-generation, not per-session). The only stable session identity available is `request.transcript.entries.first.map { $0.id }` — the first transcript entry's `id: String` never changes within a session.

## How cross-turn caching works

`LLMModel.prepare(_:cache:windowSize:)` processes tokens through the model calling `callAsFunction(tokens, cache:)`. Each call increments `cache.offset`. After turn N ends, `cache[0].offset` equals the total tokens processed (prompt + all generated tokens). On turn N+1, if we pass the SAME cache AND only the NEW tokens (delta from offset `processedCount` onwards), `prepare()` places those new KV values at positions `processedCount`, `processedCount+1`, etc. — exactly correct. RoPE embeddings use `cache.ropeOffset` which equals the current offset, so positions are right.

## Implementation plan

### 1. Add `actor ExecutorCacheStore` to `MLXFoundationModels` target

```swift
// New file: Libraries/MLXFoundationModels/ExecutorCacheStore.swift
actor ExecutorCacheStore {
    static let shared = ExecutorCacheStore()
    private init() {}

    struct SessionKVState {
        var cache: [KVCache]
        var processedTokenCount: Int
    }

    private var states: [String: SessionKVState] = [:]

    func state(for key: String, allocating: () -> [KVCache]) -> SessionKVState {
        if let existing = states[key] { return existing }
        let s = SessionKVState(cache: allocating(), processedTokenCount: 0)
        states[key] = s
        return s
    }

    func update(key: String, processedTokenCount: Int) {
        states[key]?.processedTokenCount = processedTokenCount
    }

    func invalidate(key: String) {
        states.removeValue(forKey: key)
    }
}
```

### 2. Add `sessionKey(for:)` helper to `Executor`

```swift
private func sessionKey(for transcript: Transcript) -> String? {
    transcript.entries.first.map { $0.id }
}
```

The `Transcript.Entry` subtypes all expose `public var id: String`. Use the first entry's ID; it's stable for the life of the session and uniquely identifies it.

### 3. Modify the `container.perform` closure in `Executor.respond()` (around line 881)

After building `userInput` and before calling `runUnconstrained` / `runGuidedGeneration` / `runReasoning`:

```swift
// Tokenize the FULL transcript to get all tokens
let fullInput = try await context.processor.prepare(input: userInput)
let allTokens = fullInput.text.tokens  // MLXArray, shape [totalTokenCount]

// Look up or create the persistent session cache
let key = self.sessionKey(for: request.transcript)
let kvState = key == nil ? nil : await ExecutorCacheStore.shared.state(for: key!) {
    context.model.newCache(parameters: params)
}
let cache = kvState?.cache       // nil → generate() allocates a fresh cache (ephemeral sessions)
let alreadyCached = kvState?.processedTokenCount ?? 0

// Build delta input: only tokens NEW since the last turn
let deltaTokens: LMInput.Text
if alreadyCached > 0 && alreadyCached < allTokens.size {
    deltaTokens = .init(tokens: allTokens[alreadyCached...])
} else {
    deltaTokens = fullInput.text
}
let deltaInput = LMInput(text: deltaTokens)
```

Pass `deltaInput` and `cache` down to `runUnconstrained`, `runGuidedGeneration`, and `runReasoning`. Those functions currently take `input: LMInput` — add an optional `cache: [KVCache]?` parameter to each.

### 4. Update `generate()` call sites in `runUnconstrained`, `runGuidedGeneration`, `runReasoning`

Each currently calls `generate(input:parameters:context:)` — change to `generate(input:cache:parameters:context:)` passing the session cache.

### 5. Record processed token count after generation

After the `for await generation in try generate(...)` loop completes, if `key != nil`:

```swift
// cache[0].offset is authoritative after generation
if let key, let newOffset = cache?.first?.offset {
    await ExecutorCacheStore.shared.update(key: key, processedTokenCount: newOffset)
}
```

### 6. Report cached tokens correctly in `.updateUsage`

Currently all `.updateUsage` calls hardcode `cachedTokenCount: 0`. Replace with:
```swift
cachedTokenCount: alreadyCached
```

### 7. Acceptance criteria

- `cachedTokenCount` reported in `.updateUsage` is > 0 on second and later turns of the same session
- `promptTokenCount` in `.info` equals only the NEW tokens processed that turn (not full transcript)
- Two distinct `LanguageModelSession` instances using the same model do NOT share caches (different `sessionKey`)
- An ephemeral session (empty transcript) gets a fresh cache every time, no store entry
- The `ExecutorCacheStore` is in the `MLXFoundationModels` target in `mlx-swift-lm` fork

## Files to change (all in `mlx-swift-lm` fork at `swissarmyhammer/mlx-swift-lm`)

- `Libraries/MLXFoundationModels/ExecutorCacheStore.swift` — new file
- `Libraries/MLXFoundationModels/MLXLanguageModel.swift` — `Executor.respond()`, `runUnconstrained()`, `runGuidedGeneration()`, `runReasoning()`
