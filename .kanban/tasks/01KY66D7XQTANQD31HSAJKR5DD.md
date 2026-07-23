---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Dedupe generate() calls in RoutedSession.respond(to:maxTokens:)
---
## What

A fresh `review working` pass (2026-07-22, while resolving task 9drp1rz's findings) found a new, unrelated duplication: `Sources/FoundationModelsRouter/Session/RoutedSession.swift`'s `respond(to:maxTokens:)` has two nearly-identical branches that both call `generate`, differing only in whether `grammar` is passed and which `backend.respond` overload the closure calls:

```swift
if let grammar {
    return try await generate(grammar: grammar, prompt: prompt) { composedPrompt in
        try await backend.respond(to: composedPrompt, following: grammar, maxTokens: maxTokens)
    }
}
return try await generate(prompt: prompt) { composedPrompt in
    try await backend.respond(to: composedPrompt, maxTokens: maxTokens)
}
```

Reviewer's suggested fix: unify into a single `generate(grammar: grammar, prompt: prompt) { ... }` call, moving the `if let grammar` backend-dispatch decision inside the closure.

## Acceptance Criteria
- [ ] `respond(to:maxTokens:)` calls `generate` exactly once, with the grammar/no-grammar backend dispatch decided inside the closure
- [ ] `swift build`, `swift build --build-tests`, `swift test` all green, no regressions
- [ ] `review working` on the file finds zero recurrence of this finding

## Note
Pre-existing code, not introduced by task 9drp1rz — logged separately per "no unrelated refactors while implementing" convention rather than folded into that task's fix. #bug