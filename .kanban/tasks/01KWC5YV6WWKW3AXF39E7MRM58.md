---
comments:
- actor: wballard
  id: 01kwd9z7ggxrpccbj0t5q99qpm
  text: 'Picked up 5b. Researched current APIs: RoutedModel/RoutedLLM (LanguageModelProfile.swift) carries routerID + non-optional recorder but NO back-ref to its owning profile; LoadedLLMContainer is an empty marker; RoutedEmbedder.embed is the prevailing surface pattern (container-constrained extension + EmbeddingError.notWiredForLiveInference on the live container). Plan: (1) extend LoadedLLMContainer with respond/streamResponse requirements (live ModelContainer throws GenerationError.notWiredForLiveInference, mirroring the embedder); (2) add a weak owning-profile back-ref box to RoutedModel so a vended session can retain its profile WITHOUT a retain cycle (cycle would defeat the profile''s deinit-driven eviction); (3) thread recordingsRoot from Router into RoutedModel so recordingDirectory is router-rooted; (4) RoutedSession protocol + internal actor with a single recorder-bracketed generate chokepoint; (5) makeSession on RoutedLLM. Starting TDD with SessionChokepointTests.'
  timestamp: 2026-06-30T22:21:36.144184+00:00
- actor: wballard
  id: 01kwdaafejfa77parvds5amfc3
  text: |-
    Implementation landed (TDD: wrote SessionChokepointTests first, confirmed RED via missing makeSession/RoutedSession/SessionError, then GREEN).

    What was built:
    - LoadedLLMContainer (ModelLoader.swift) extended with respond(to:instructions:) + streamResponse(to:instructions:) requirements. Live ModelContainer (LiveModelLoader.swift) implements both throwing GenerationError.notWiredForLiveInference (mirrors the embedder seam). GenerationError lives in new RoutedLLM.swift.
    - RoutedModel gained `recordingsRoot: URL?` (threaded from Router.recordingsDir in buildProfile) and an internal `owningProfileBox = OwningProfileBox()` (lock-guarded WEAK back-ref). LanguageModelProfile.init registers itself into all three boxes after full init. Weak avoids a retain cycle so the profile's deinit-driven eviction still works.
    - RoutedLLM.swift: makeSession(instructions:workingDirectory:) on RoutedModel where Container == any LoadedLLMContainer. Vends RoutedSessionActor, retaining owningProfileBox.current! (total by construction). recordingDirectory = (recordingsRoot ?? temp base)/routerID/sessionID; workingDirectory defaults to it.
    - Session/RoutedSession.swift: `protocol RoutedSession: Actor` (nonisolated profile/routerID/id/parentID/recordingDirectory/workingDirectory; respond/streamResponse/fork). SessionError.forkNotWiredUntilMilestone9. Internal actor RoutedSessionActor with internal init (no public initializer). Single private generate<R> chokepoint: append open (.prompt), run body, append close (.response) on BOTH success and throw (do/catch rather than async-defer since Swift defer can't await — faithful equivalent, documented). respond + streamResponse both funnel through it. fork throws the milestone-9 placeholder. Raw container never vended.
    - Updated empty StubLLMContainer conformances in ResolveTests + ProfileLifecycleTests to satisfy the new protocol (throw notWired; never generate there).

    Tests: SessionChokepointTests (6) cover respond open/close+provenance, streaming open/close, close-on-throw, profile retention (eviction spy: count stays 0 for 100ms while session alive, becomes 3 after last session dropped), workingDirectory default+override, fork-throws.

    Verified GREEN with DEVELOPER_DIR=Xcode-beta: swift build clean (no warnings), swift test --filter SessionChokepointTests = 6/6, full swift test = 67 + 1 integration placeholder, zero failures. Running adversarial double-check next.
  timestamp: 2026-06-30T22:27:44.722661+00:00
- actor: wballard
  id: 01kwdam0qzf1tn38byyed7qtz1
  text: |-
    Adversarial double-check returned REVISE with two findings; both addressed:

    1. (Medium) Force-unwrap `owningProfileBox.current!` in makeSession could trap opaquely if a caller cached a RoutedLLM handle (which holds its profile weakly) and released the profile before calling makeSession. Fixed: replaced the bare `!` with `guard let owningProfile = owningProfileBox.current else { preconditionFailure("makeSession requires a live owning LanguageModelProfile; ...") }`, and documented the precondition on makeSession. This remains a trap on the same illegal misuse path (profile already evicted) — just with a clear diagnostic instead of a nil-unwrap — so no new test (Swift Testing can't assert a preconditionFailure trap, and there's no new success path).

    2. (Low) Protocol doc overstated serialization given actor reentrancy. Fixed: the RoutedSession doc now states each call's bracket is individually balanced (exactly one open/close) but concurrent calls on one session may interleave their balanced events because generation suspends at await points; strict per-session serialization is deferred to the milestone-9 concurrency gates.

    The double-check independently CONFIRMED: no retain cycle (session→profile→RoutedModel→box→(weak)profile; deinit-driven eviction proven by the retention test), the chokepoint emits exactly one open+one close on success/throw/stream incl. early-termination/cancellation (onTermination cancels the Task, both do/catch arms append one close), no public initializer (actor + init both internal), and Swift 6 soundness (all nonisolated lets Sendable; @unchecked Sendable box lock-guarded).

    Re-verified GREEN after the fixes (DEVELOPER_DIR=Xcode-beta): swift build clean (no warnings), full swift test = 67 + 1 integration placeholder, zero failures. Leaving task in `doing` for /review.
  timestamp: 2026-06-30T22:32:57.343660+00:00
depends_on:
- 01KWC5FTDFTSW3BA82MXE6CGP0
- 01KWC5ECCZYEAH49J635KC9QH5
position_column: doing
position_ordinal: '80'
title: RoutedSession actor + recording chokepoint + makeSession (milestone 5b)
---
## What
The generation session surface, born holding a recorder. Plan "Access API", "Sessions & KV cache" (basic), "Sessions: working directory & isolation", "Transcripts & recording" (chokepoint). Forking + concurrency gates are milestone 9; full nesting/manifest is milestone 10.

- `Sources/FoundationModelsRouter/RoutedLLM.swift`:
  - `func makeSession(instructions: String? = nil, workingDirectory: URL? = nil) -> RoutedSession`, vending a session that inherits the `RoutedLLM`'s `routerID` + non-optional `TranscriptRecorder` (from milestone 4b).
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:
  - `protocol RoutedSession: Actor` with `profile` (retained), `routerID: ULID`, `id: ULID`, `parentID: ULID?`, `recordingDirectory: URL`, `workingDirectory: URL` (defaults to recordingDirectory), `respond(to:)`, `streamResponse(to:)` (unconstrained text only). `fork(workingDirectory:)` declared but its real KV-copy behavior is milestone 9.
  - Concrete actor backed by `MLXLMCommon` `ChatSession` / `ModelContainer`. **No public initializer** — only vended by `RoutedLLM.makeSession`; recorder + `routerID` flow down from the Router.
  - **Single bracketed `generate` chokepoint:** every public method (`respond`, `streamResponse`) funnels through one private `generate` that runs the model inside a recorder bracket (open event → body → close/error in `defer`). Recorder is a non-optional `let`; milestone 10 enriches the events + nesting.
  - The raw `ChatSession` is never vended.

## Acceptance Criteria
- [ ] `makeSession().respond(to:)` returns text (covered for real in the gated integration suite); with a stub model the chokepoint emits exactly one open + one close event to an `InMemoryRecorder`, and a close event even when the body throws.
- [ ] A session retains its profile: dropping the profile handle while a session is alive does NOT evict; eviction happens after the last session is released (assert via the eviction spy from milestone 5a).
- [ ] `workingDirectory` defaults to `recordingDirectory` and is overridable via `makeSession(workingDirectory:)` without moving the recording directory.
- [ ] There is no public `RoutedSession` initializer (compile-time: construction only via `makeSession`).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SessionChokepointTests.swift` (Swift Testing) with a stub `ModelContainer`/loader + `InMemoryRecorder`: chokepoint emits open/close (incl. on throw); profile-retention via eviction spy; workingDirectory default + override.
- [ ] Run `swift test --filter SessionChokepointTests` — all pass.

## Workflow
- Use `/tdd` — write failing chokepoint + retention + workingDirectory tests with stubs first.