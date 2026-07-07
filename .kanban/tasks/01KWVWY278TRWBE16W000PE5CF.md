---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwwq35v31k4v8jp3pjdfya2z
  text: '/finish scoped-batch run: picked up this task (lowest ordinal ready task, just unblocked by ^5wvxhnk landing in done). Note: task ^5wvxhnk''s implementation already created a first-pass `MLXFoundationModelsSessionBackend` in LiveModelLoader.swift as a necessary follow-on to keep the production target compiling — this task should audit that existing implementation against its own acceptance criteria (Sendable annotation + comment, makeFork() via transcript, internal session accessor, schema-based respond, etc.) rather than assuming a blank slate. Starting implement.'
  timestamp: 2026-07-06T21:59:33.475535+00:00
- actor: claude-code
  id: 01kwwr52gg38cg3hawptjq001h
  text: |-
    Implementation landed in Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift. What was already present (from ^5wvxhnk's necessary follow-on): the factory shape (`MLXFoundationModelsContainer.makeSession(instructions:)` returning a `MLXFoundationModelsSessionBackend`), the guided-generation `respond(to:following:)` path, the streaming suffix-diff adapter, and `Sendable` conformance (but only plain `Sendable`, not `@unchecked`). What was NOT present and had to change for this task's actual acceptance criteria: the backend rebuilt a brand-new `LanguageModelSession` on every single call (respond, streamResponse, and even inside its own guided path) and `makeFork()` just made an equivalent fresh backend from the same model/instructions — i.e. no conversation state ever accumulated, and forking carried nothing forward. Rewrote so:
    - `MLXFoundationModelsSessionBackend` now holds one `private let liveSession: LanguageModelSession` for its entire lifetime; `respond`/`streamResponse`/guided-respond all run through it, so a second call sees the first turn's context.
    - Backend is now `final class ...: LanguageModelSessionBackend, @unchecked Sendable`, with a doc comment citing `RoutedSessionActor.serialGate` (AsyncSemaphore@1) as the concurrency-safety mechanism, per the AC.
    - Added `internal var session: LanguageModelSession { liveSession }` — test-only accessor, not on the protocol.
    - `makeFork()` now does `LanguageModelSession(model: model, tools: [], transcript: liveSession.transcript)` and wraps the result in a fresh backend, so a fork is seeded from the parent's accumulated transcript instead of being an independent, context-free backend.
    - `MLXFoundationModelsContainer.makeSession(instructions:)` builds the `LanguageModelSession` once and hands it to the backend's new `init(session:model:)`.

    Verified `swift build --target FoundationModelsRouter` green (fresh run, exit 0, "Build complete!").

    Tests: added `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` (a NEW file in the *integration* test target, not the existing GPU-free `Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift` that plan.md documents as schema-conversion-only unit coverage) with two gated `@Test`s under the same `FM_ROUTER_INTEGRATION_TESTS` env-var + tiny-model pattern as `IntegrationTests.swift`: (1) a second `respond()` call sees the first turn's content, (2) `makeFork()`'s child transcript count matches the parent's at fork time. Verified the exact `LanguageModelSession`/`Transcript` API surface directly against the real macOS 27 SDK's `FoundationModels.swiftinterface` rather than guessing.

    Discovery (not caused by this task, filed separately as ^2bgsqbe): `swift build --build-tests` currently fails for BOTH test targets due to unrelated, pre-existing argument-label mismatches against `ModelLoader`/`LoadedEmbeddingContainer` in test stubs (introduced by commit 825f7c7 and siblings, before this task). Confirmed via `git diff --stat` that I never touched those files. Because of this, I could not get my new integration test file to actually build/run in this sandbox (no network for the gated download either) — verified it only via `swiftc -parse` (syntax-clean) and careful manual review against the SDK interface, plus the fact the library target itself builds clean.

    Adversarial double-check dispatched; will report its verdict once back.
  timestamp: 2026-07-06T22:18:04.176308+00:00
- actor: claude-code
  id: 01kwwrfmsbebkhjjn0hchbc65h
  text: 'Adversarial double-check verdict: PASS. Independently re-verified the RoutedSessionActor.serialGate claim, the LanguageModelSession/Transcript API surface against the real macOS 27 SDK swiftinterface, re-ran `swift build --target FoundationModelsRouter` (green), and re-confirmed the pre-existing `swift build --build-tests` breakage predates this change and is correctly scoped out to ^2bgsqbe. One residual gap flagged for awareness (not a defect in this diff''s scope): `RoutedSessionActor.respond`/`streamResponse` still call `container.makeSession(instructions:)` fresh per turn, so the new transcript-accumulation behavior isn''t yet reachable through the production Router path — that''s exactly what the next task (^rqgzwa4, "Update RoutedSessionActor to own and drive a LanguageModelSessionBackend") wires up. Leaving this task in `doing` for `/review`.'
  timestamp: 2026-07-06T22:23:50.571518+00:00
- actor: claude-code
  id: 01kwy7y2mw5982xazg6pxf5kdt
  text: |-
    Addressed all three review findings from 2026-07-07 06:13:

    1. Correctness bug (makeFork not preserving instructions): Added `private let instructions: String?` to `MLXFoundationModelsSessionBackend`, threaded it through `init(session:model:instructions:)`, `MLXFoundationModelsContainer.makeSession(instructions:)` now passes it in, and `makeFork()` now passes `instructions: instructions` into the forked backend's init. Note: empirically verified (via a standalone `swift` script against the real macOS 27 SDK) that `LanguageModelSession(model:instructions:)` records instructions as a `Transcript.Entry.instructions` first entry, and that entry is already carried forward faithfully when reconstructing via `LanguageModelSession(model:tools:transcript:)` (what makeFork() uses) — there is no SDK initializer accepting both `transcript:` and `instructions:` together, so the fix makes `instructions` an explicit, threaded, stored/testable property on the backend rather than literally passing it into the transcript-based constructor call (which isn't possible). Functionally this closes the gap the reviewer flagged (no property existed at all before) while documenting the real mechanism accurately in the doc comments.

    2. Style (mapProgress missing explicit access modifier): Changed `static func mapProgress` to `internal static func mapProgress` in LiveModelLoader.swift. No visibility change, matches the file's explicit-access-level convention.

    3. Test strengthening (makeForkSeedsFromParentTranscript): Added a `child.respond(to: "What number should I remember?...")` call after the fork, asserting the reply contains "42" (the number the parent was told to remember pre-fork) — proving the fork actually sees prior-turn content, not just matching transcript counts. Updated the final divergence assertion to compare against the child's post-own-turn count rather than the stale parent-at-fork-time count.

    Verified `swift build --target FoundationModelsRouter` green (fresh run, exit 0, "Build complete!"). Confirmed `swift build --build-tests` still fails with the same pre-existing, unrelated `ProfileLifecycleTests.swift` missing-argument-label errors (tracked separately as ^5wvxhnk / 01KWVWZJMYGB295V9C0QZWTM1M) — git diff confirms I never touched that file or any ModelLoader/LoadedEmbeddingContainer signatures.

    Adversarial double-check dispatched to independently verify all three fixes; will report its verdict once back.
  timestamp: 2026-07-07T12:13:06.588247+00:00
- actor: claude-code
  id: 01kwy844g7f8vjdaqaf0dyq65n
  text: |-
    Adversarial double-check verdict: PASS. Independently confirmed all three fixes:

    1. Both `MLXFoundationModelsSessionBackend(...)` call sites updated consistently (grep-confirmed, only two in the tree). Independently verified against the real macOS 27 SDK swiftinterface that no `LanguageModelSession` initializer accepts both `transcript:` and `instructions:` together, and wrote its own throwaway swift script confirming `.instructions` transcript entries are already carried forward through `init(model:tools:transcript:)` — so the stored `instructions` property is correctly a metadata-level fix layered on the (already-correct) transcript mechanism, not a behavioral change, and introduces no regression risk (no double-application/precedence conflict, since makeFork()'s `LanguageModelSession(...)` call still takes no `instructions:` argument).
    2. `mapProgress` access-modifier change confirmed as the only diff at that site; doc comment still accurate.
    3. Test strengthening confirmed: gating unchanged, new `child.respond()` assertion is a real content-awareness proof (not just a count match), and the final divergence assertion was correctly updated to compare against `childEntryCountAfterOwnTurn` instead of the now-stale `parentEntryCountAtForkTime`. `swiftc -parse` clean.

    Also independently re-ran `swift build --target FoundationModelsRouter` (exit 0, "Build complete!") and confirmed `swift build --build-tests` fails only on the pre-existing, unrelated `ProfileLifecycleTests.swift` argument-label issue (^5wvxhnk / 01KWVWZJMYGB295V9C0QZWTM1M), via git diff showing that file untouched.

    Leaving this task in `doing` for `/review`.
  timestamp: 2026-07-07T12:16:25.095764+00:00
depends_on:
- 01KWVWXHMHR3XM8PM6T5WVXHNK
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-07-07 06:13)

- [ ] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:232` — makeFork() does not preserve the instructions that were passed when creating the parent session. The `instructions` property was deleted from the class, making it impossible to pass instructions to the forked session's `LanguageModelSession` constructor. Store `instructions` as a property in `MLXFoundationModelsSessionBackend`, pass it to `makeSession` in the container (modify the signature to also accept instructions), and pass it to the forked `LanguageModelSession` in `makeFork()`.
- [ ] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:538` — Member of a public struct should have explicit access modifier rather than relying on implicit `internal`. All other static members in this struct are explicitly marked as `private`, making this one inconsistent. Add explicit `internal` modifier: `internal static func mapProgress(_ progress: Progress) -> DownloadProgress {`.
- [ ] `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift:92` — The `makeForkSeedsFromParentTranscript` test creates a parent session with custom instructions and forks it, but only verifies that the transcript count is preserved. It never calls `respond()` on the forked session to verify that the fork actually works correctly or can access the parent's prior conversation content. Add a call to `child.respond()` asking about the content from the parent's prior turn (e.g., 'What number should I remember?' after the parent responded to 'Remember the number 42.'), and verify the child can correctly access that context.
