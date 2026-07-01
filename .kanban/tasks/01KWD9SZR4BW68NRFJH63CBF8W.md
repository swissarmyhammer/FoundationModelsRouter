---
comments:
- actor: wballard
  id: 01kwf67y7qjh6wnncss6nrp7qe
  text: 'Picked up. Researched the full shipped public API surface against the existing suites (ResolveTests, SessionChokepointTests, ForkConcurrencyTests, GuidedGenerationTests, GuidedShapesTests, ProfileLifecycleTests) and the source: ProfileDefinition, Router.resolve(_:reporting:), ResolutionProgress (@MainActor @Observable, phase/.ready + fraction), LanguageModelProfile (standard/flash/embedding, release()), RoutedLLM.makeSession(instructions:)/respond(to:)/streamResponse(to:), RoutedEmbedder.embed([...])/dimension, guided respond(to:following:)/makeGuidedSession/respond(to:matching:)->JSONValue/respond(to:generating:) (gated), RoutedSession.fork(workingDirectory:), RouterError.profileAlreadyResident, GuidedRequestError, Grammar, JSONValue (.bool/.number(Double)/.string/.object). Writing ExamplesTests.swift with one @Test per usage pattern, stub wiring confined to a single ExampleHarness helper, typed-guided test gated under #if canImport(FoundationModels).'
  timestamp: 2026-07-01T15:54:56.119542+00:00
- actor: wballard
  id: 01kwf6c0mr6ptk426ncnv7rdv6
  text: |-
    Awkward-API observations surfaced while writing the examples (flagging, not papering over):

    1. `streamResponse(to:)` requires `await` at the CALL site to obtain the stream (it is actor-isolated and returns the AsyncThrowingStream synchronously), so consumer code reads `for try await fragment in await session.streamResponse(to:)`. The double `await ... await` on one line is a minor readability wrinkle — the outer await is just to reach the actor, not to stream. Sibling SessionChokepointTests has the same shape, so it is pre-existing, not introduced here. Not blocking; noting as a possible future ergonomics improvement (e.g. a nonisolated streaming entry point).

    2. `fork(workingDirectory:)` has no zero-arg convenience: the common "just fork me" case must be written `fork(workingDirectory: nil)`. Reads slightly verbose in the subagent fan-out example. A `fork()` overload defaulting workingDirectory to nil would make the fan-out pattern cleaner. Non-blocking.

    Everything else (ProfileDefinition authoring, resolve+ResolutionProgress, makeSession/respond, embed/dimension, all three guided shapes, release()/one-active-profile via RouterError) read cleanly as production usage.
  timestamp: 2026-07-01T15:57:09.656969+00:00
- actor: wballard
  id: 01kwf6ndfk0yrwm12xw918ttyk
  text: |-
    Done and green in `doing`. ExamplesTests.swift added (9 @Tests, one per usage pattern): resolveProfileObservingProgress, generateWithASession, streamAResponse, embedStrings, guidedRawConstrainedText, guidedDynamicJSONValue (-> JSONValue), guidedTypedGenerable (gated under #if canImport(FoundationModels)), subagentFanOutByForking, residencyOneActiveProfileAndRelease. Stub wiring confined to the single ExampleHarness enum; header doc marks the file the canonical usage reference.

    Verification (env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer):
    - `swift test --filter ExamplesTests` -> 9/9 pass.
    - full `swift test` -> 119 tests in 19 suites pass; gated milestone-7 integration suite skipped as designed. No network/GPU/download.

    Adversarial double-check verdict: PASS. Traced every call to the shipped API; all seven required patterns present as distinct @Tests, assertions non-vacuous, seam confined, offline/order-independent (unique-UUID temp cacheDir, InMemoryRecorder, recordingsDir nil).

    Advisory finding (proceeding with logged justification): makeRouter creates a throwaway temp cacheDir per call and does not remove it (siblings defer-remove theirs). Kept as-is deliberately: the task's explicit priority is that example bodies "look exactly like production code", and per-test defer cleanup would leak test-hygiene noise into the bodies (or force the harness to hand back a teardown handle). The dirs are unique-UUID, empty, in OS temp, cause no collision/flakiness, and a real consumer keeps its cache dir. Harmless and does not violate any acceptance criterion.

    Left in `doing` for /review.
  timestamp: 2026-07-01T16:02:17.715749+00:00
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5HV9BBARA3HJA26MMV0YC
- 01KWC5H7Y7NVG4771FR9ZKW5M0
- 01KWC5JSV0GM6AM05C6TXGN0TS
position_column: done
position_ordinal: '9580'
title: 'Capstone: example/usage unit tests as living API documentation'
---
## What
Per user request (2026-06-30): provide a set of unit tests that are clear, readable **samples of using the public API end-to-end** — a capstone that doubles as living documentation. Distinct from the gated milestone-7 integration suite (`txgn0ts`): these run **offline in the normal unit-test target** (no network/GPU, no download), so they stay green in CI and demonstrate the call patterns a real consumer writes.

- `Tests/FoundationModelsRouterTests/ExamplesTests.swift` (Swift Testing) — a small, heavily-commented suite where each `@Test` is a self-contained "how do I…" example. The body must read like REAL usage: define a `ProfileDefinition` (Swift-literal manifest, biggest/best first), construct a `Router`, `resolve` it, then use the resolved profile. Isolate the unit-test seam (injected stub `ModelLoader` + `MetadataSource` + `MachineProbe`, and an `InMemoryRecorder`) to ONE clearly-commented setup helper so the example bodies themselves look exactly like production code. Add a header doc comment pointing readers here as the canonical usage reference.
- Cover, as separate named examples (use whichever public APIs exist once dependencies are done):
  - Authoring a `ProfileDefinition` + resolving via `Router.resolve(_:reporting:)`, observing `ResolutionProgress` advance to `.ready`.
  - Generation: `profile.standard.makeSession(instructions:)` then `respond(to:)`; and `streamResponse(to:)` consuming the stream.
  - Embedding: `profile.embedding.embed([...])` and reading `dimension`.
  - Guided generation, all three shapes: typed `respond(to:generating:)`, dynamic-JSON `respond(to:matching:)`, and raw `respond(to:following:)` / `makeGuidedSession`.
  - Subagent fan-out: a guided/template session `fork()`ed N times (the plan's "many short-lived forks" pattern).
  - Residency lifecycle: `release()` and one-active-profile.
- Keep each example minimal and copy-pasteable; prefer clarity over coverage (correctness coverage lives in the per-feature suites). If a planned API shifts during implementation, this task updates the examples to match the final surface.

## Acceptance Criteria
- [ ] `Tests/FoundationModelsRouterTests/ExamplesTests.swift` exists with one clearly-named `@Test` per usage pattern above, each reading like real consumer code (stub wiring confined to a single commented setup helper).
- [ ] The suite runs in the NON-gated unit target — green under `swift test` with no network/GPU/download.
- [ ] Examples exercise the actual shipped public API (compile against the real types/signatures; no pseudo-code), covering resolve+progress, session respond + stream, embed, all three guided shapes, fork fan-out, and release/one-active-profile.
- [ ] A header doc comment designates this file as the canonical usage reference.

## Tests
- [ ] The suite IS the test. Run `swift test --filter ExamplesTests` (env `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — all pass; confirm full `swift test` stays green.

## Workflow
- Use `/tdd` — write each example as an executable assertion of the documented call pattern; if an API reads awkwardly in an example, that is a signal to flag (not to paper over).