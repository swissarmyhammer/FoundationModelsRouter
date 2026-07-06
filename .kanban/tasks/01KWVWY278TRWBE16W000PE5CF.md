---
assignees:
- claude-code
depends_on:
- 01KWVWXHMHR3XM8PM6T5WVXHNK
position_column: todo
position_ordinal: '8180'
title: Implement MLXFoundationModelsSessionBackend wrapping LanguageModelSession
---
## What

Implement the live `LanguageModelSessionBackend` conformance. `MLXFoundationModelsContainer` becomes the factory; a new `MLXFoundationModelsSessionBackend` class wraps the live `LanguageModelSession`.

**New type** `MLXFoundationModelsSessionBackend` (in `LiveModelLoader.swift`):
- `final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend`
- Marked `@unchecked Sendable` — `LanguageModelSession` is itself `@unchecked Sendable` (confirmed: `extension FoundationModels::LanguageModelSession : @unchecked Swift::Sendable` in the macOS 27 SDK interface). Concurrent access is safe because `RoutedSessionActor.serialGate` (AsyncSemaphore at value 1) ensures only one generation call runs at a time. Add a comment to that effect.
- `private let session: LanguageModelSession` — held for this backend's lifetime
- `private let model: MLXLanguageModel` — needed to seed forks
- `internal var session: LanguageModelSession { session }` — `internal` accessor for `@testable import` in integration tests (NOT on the protocol — test-only surface)
- `respond(to:maxTokens:)` → `session.respond(to:options:)`
- `streamResponse(to:maxTokens:)` → `session.streamResponse(to:options:)` with suffix-diff adapter (same as today)
- `respond(to:following:maxTokens:)` → `session.respond(to:schema:options:)` via `RuntimeJSONSchemaConverter`
- `makeFork()` → reads `session.transcript`, constructs `LanguageModelSession(model: model, tools: [], transcript: session.transcript)`, wraps in a fresh `MLXFoundationModelsSessionBackend`

**Update** `MLXFoundationModelsContainer`:
- Remove `respond`, `streamResponse`, `respond(following:)` methods
- Add `func makeSession(instructions: String?) -> any LanguageModelSessionBackend` creating `LanguageModelSession(model: model, instructions: instructions)` wrapped in `MLXFoundationModelsSessionBackend`

## Acceptance Criteria
- [ ] `MLXFoundationModelsSessionBackend` is `@unchecked Sendable` with a comment citing the `serialGate` as the safety mechanism
- [ ] `MLXFoundationModelsContainer.makeSession(instructions:)` is implemented and returns `MLXFoundationModelsSessionBackend`
- [ ] `makeFork()` seeds the fork from `session.transcript` via `LanguageModelSession.init(model:tools:transcript:)`
- [ ] `internal var session: LanguageModelSession` accessor exists on `MLXFoundationModelsSessionBackend` (not on the protocol)
- [ ] Old stateless `respond`/`streamResponse` removed from `MLXFoundationModelsContainer`
- [ ] `swift build --target FoundationModelsRouter` succeeds

## Tests
- [ ] Integration tests in `LanguageModelSessionBackendTests.swift`: second `respond` call sees prior turn's content in context (requires live model, gated)
- [ ] Integration test: `makeFork()` produces a session whose `session.transcript.entries.count` equals the parent's entry count at fork time

## Workflow
- `/tdd` — write integration assertions first (they fail with current single-turn implementation), then implement the backend class.