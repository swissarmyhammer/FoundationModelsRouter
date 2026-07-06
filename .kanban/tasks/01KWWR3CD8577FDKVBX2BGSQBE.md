---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Fix ModelLoader protocol stub argument-label mismatches breaking all test targets
---
## What

`swift build --build-tests` currently fails to compile **both** test targets (`FoundationModelsRouterTests` and `FoundationModelsRouterIntegrationTests`), independent of and pre-existing any `LanguageModelSessionBackend`/`LoadedLLMContainer` factory work. Root cause: commits `825f7c7` ("refactor(api): label first parameters across handler, session, guided, and embed APIs"), `e067f54`, and `ac1e95c` added explicit external labels (`ref:`, `container:`, `texts:`) to the `ModelLoader`/`LoadedEmbeddingContainer` protocol requirements in `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`, but the test-target stub conformances were never updated to match, so their witnesses no longer satisfy the protocol requirements.

Confirmed failing declarations (positional/underscore first params that no longer match the now-labeled protocol requirements):
- `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`: `PhaseRecordingLoader.loadLLM(_:slot:context:reporting:)`, `.loadEmbedder(_:slot:reporting:)`; `DownloadObservingLoader.loadLLM(_:slot:context:reporting:)`, `.loadEmbedder(_:slot:reporting:)`; `preload(_:)` (needs `preload(container:)`).
- `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`: same `ModelLoader` stub shape, plus call sites passing `router.resolve(Self.profile, ...)` positionally where `resolve` now requires a `profile:` label.
- `Tests/FoundationModelsRouterTests/HostProfileTests.swift`/others may have the same `embed(_:)` vs `embed(texts:)` mismatch reported for `LoadedEmbeddingContainer`.

## Why this matters

This blocks `swift build --build-tests` / `swift test` for the **entire package** right now — not just the tasks already tracked for the `LanguageModelSessionBackend` factory pivot (`Update all test stubs to implement the LanguageModelSessionBackend factory seam`, which is scoped to the *factory* (`makeSession`) shape change, not this labeling defect). Discovered while implementing `MLXFoundationModelsSessionBackend` (task `00pe5cf`): `swift build --target FoundationModelsRouter` (library only) is green, but a full test build is not, for this unrelated, pre-existing reason.

## Acceptance Criteria
- [ ] Every test-target stub conforming to `ModelLoader`/`LoadedEmbeddingContainer` uses the exact argument labels the current protocol requirements declare.
- [ ] Every `router.resolve(...)` (and similar) call site uses the current labeled signature.
- [ ] `swift build --build-tests` succeeds (modulo any other in-flight, separately-tracked stub work for the `LanguageModelSessionBackend` factory pivot).
