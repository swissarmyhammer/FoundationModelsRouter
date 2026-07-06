---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwvzhgm5g360vsew5676dp12
  text: '/finish scoped-batch run: picked up this task (lowest ordinal, ready, unblocks the session-backend chain). Starting implement.'
  timestamp: 2026-07-06T15:07:57.445884+00:00
- actor: claude-code
  id: 01kww0pfdq23by8q25fs05ga8n
  text: |-
    Implemented:
    - New Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift protocol (respond, streamResponse, respond(following:), makeFork), class-bound + Sendable.
    - ModelLoader.swift: LoadedLLMContainer now exposes only makeSession(instructions:) -> any LanguageModelSessionBackend; removed the three stateless generation methods and makeCache().
    - GuidedGeneration.swift: removed the default LoadedLLMContainer extension for respond(to:instructions:following:maxTokens:).
    - SessionKVCache.swift: removed the default LoadedLLMContainer.makeCache() extension (SessionKVCache protocol + InertKVCache class kept).

    Beyond the literal "Modify" list, also updated the other production (Sources/) call sites that referenced the removed protocol members, since the task's own acceptance criterion requires the whole `swift build --target FoundationModelsRouter` to keep succeeding, not just the 3 listed files:
    - LiveModelLoader.swift: MLXFoundationModelsContainer.makeSession(instructions:) now returns a new MLXFoundationModelsSessionBackend class holding the moved respond/streamResponse/respond(following:) bodies (behaviorally unchanged: fresh LanguageModelSession per call). makeFork() returns an equivalent fresh backend for now (no transcript state to seed from yet) -- real transcript-seeded fork is task 00pe5cf's job.
    - RoutedLLM.swift: container.makeCache() replaced with InertKVCache() directly.
    - RoutedSession.swift (RoutedSessionActor): respond/streamGenerating now call container.makeSession(instructions:) once per call to get a backend, then drive it -- preserves today's exact per-call-fresh-session behavior. Deliberately did NOT make the actor hold the backend as persistent state across calls or add serialGate-guarded fork (that's task rqgzwa4's explicit scope).

    Verification: `swift build --target FoundationModelsRouter` succeeds (exit 0). `swift build --build-tests` fails only in the test target (stub containers missing makeSession(instructions:)) -- expected/permitted per the task's note; task qzwtm1m fixes those stubs.

    Leaving task in doing for review per /implement workflow.
  timestamp: 2026-07-06T15:28:08.631263+00:00
- actor: claude-code
  id: 01kww119jw91n9s04a5ttvj76x
  text: |-
    Adversarial double-check (via really-done) ran: verdict REVISE with one finding — SessionKVCache.swift's "Historical note" doc comment still said "the live container inherits the inert default below unchanged," which became stale once makeCache()'s default extension was deleted (RoutedLLM.swift now constructs InertKVCache() directly, not via any container-inherited default). Fixed the wording to describe the new mechanism accurately. Everything else the double-check checked passed: protocol shape matches spec verbatim, ModelLoader.swift/GuidedGeneration.swift/SessionKVCache.swift diffs match the task's 4 required changes exactly, no remaining Sources/ call sites reference the removed container methods, and the task1-vs-task2/task3 scope boundary was judged sound (no preemption of MLXFoundationModelsSessionBackend's @unchecked Sendable/session-accessor/transcript-fork work, no preemption of RoutedSessionActor's persistent-backend/cache-removal/serialGate-fork work).

    Re-verified after the fix: `swift build --target FoundationModelsRouter` still exits 0 ("Build complete!"). Task is green and ready for /review; leaving in doing.
  timestamp: 2026-07-06T15:34:03.100550+00:00
- actor: claude-code
  id: 01kww1420ea595pkvft97a2250
  text: 'Implement landed green: production target (`swift build --target FoundationModelsRouter`) builds clean. `swift test` fails to build only because `StubLLMContainer` (ProfileLifecycleTests.swift) and `CannedLLMContainer` (ToolIntegrationTests.swift) don''t yet implement `makeSession(instructions:)` — this is the exact, documented, expected gap called out in this task''s own description ("Test targets are expected to fail to compile until task 4 — do not attempt to fix stubs here"). Fixing those stubs is task 01KWVWZJMYGB295V9C0QZWTM1M''s job, not this one''s. Treating this as the accepted test state and proceeding to commit + review.'
  timestamp: 2026-07-06T15:35:33.646462+00:00
position_column: doing
position_ordinal: '80'
title: Define LanguageModelSessionBackend protocol and make LoadedLLMContainer a factory
---
## What

Replace the stateless generation methods on `LoadedLLMContainer` with a single factory method. The container no longer invokes generation directly — it manufactures session objects that do.

**New file:** `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`

```swift
/// A live session object vended by a LoadedLLMContainer factory.
/// Holds state (conversation transcript) across calls.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    func respond(to prompt: String, maxTokens: Int?) async throws -> String
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String
    /// Produces a new backend seeded from this session's accumulated transcript.
    func makeFork() -> any LanguageModelSessionBackend
}
```

**Modify** `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`:
- Add `func makeSession(instructions: String?) -> any LanguageModelSessionBackend` to `LoadedLLMContainer`
- Remove the three stateless generation methods: `respond(to:instructions:maxTokens:)`, `streamResponse(to:instructions:maxTokens:)`, `respond(to:instructions:following:maxTokens:)`
- Remove `makeCache() -> any SessionKVCache`

**Modify** `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift`:
- Remove the `LoadedLLMContainer` default extension for `respond(to:instructions:following:grammar:maxTokens:)`

**Modify** `Sources/FoundationModelsRouter/Session/SessionKVCache.swift`:
- Remove the `LoadedLLMContainer.makeCache()` default extension

**Note on compilation:** Removing the stateless protocol methods will cause test targets to fail to compile until task 4 updates the stubs. That is expected and accepted. Only `Sources/` production code must compile after this task.

## Acceptance Criteria
- [ ] `LanguageModelSessionBackend` protocol exists in `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`
- [ ] `LoadedLLMContainer` in `ModelLoader.swift` has only `makeSession(instructions:) -> any LanguageModelSessionBackend`; the three stateless generation methods and `makeCache()` are gone from the protocol
- [ ] `swift build --target FoundationModelsRouter` (production sources only) succeeds
- [ ] Test targets are expected to fail to compile until task 4 — do not attempt to fix stubs here

## Tests
- [ ] `swift build --target FoundationModelsRouter` exits 0

## Workflow
- Use `/tdd` — define the protocol and strip the container seam, verify production target compiles, leave test failures for task 4.