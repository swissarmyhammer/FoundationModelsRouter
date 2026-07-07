---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwyc5hzwe4raqqe8kna0ww32
  text: |-
    Started. Confirmed root cause matches the description: `ModelLoader`/`LoadedEmbeddingContainer` protocol requirements in Sources/FoundationModelsRouter/Resolution/ModelLoader.swift now use explicit labels (`ref:`, `slot:`, `context:`, `reporting:`, `container:`, `texts:`), but several test-target stub conformances still use positional/underscore first params, so their witnesses no longer satisfy the protocol.

    Also discovered (unrelated, out of scope for this task): `swift build` / `swift build --build-tests` currently fail for the *entire* package before even reaching FoundationModelsRouter's own sources, due to a beta-SDK API drift in the vendored `mlx-swift-lm` fork dependency: `.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift` pattern-matches `GenerationOptions.SamplingMode.Kind` cases `.top(let k, _)` / `.nucleus(let threshold, _)`, but the current Xcode 27 beta (Swift 6.4, macOS27.0 SDK) FoundationModels.framework interface now names these cases `.randomTopK(_: Int, seed: UInt64?)` / `.randomProbabilityThreshold(_: Double, seed: UInt64?)` — confirmed by reading the SDK's arm64e-apple-macos.swiftinterface directly. The pinned mlx-swift-lm revision (e6ccd27, `mlx-foundationmodels` branch) is already at the branch HEAD, so this isn't a stale-pin issue — it's a genuine SDK/toolchain incompatibility in a different repo, unrelated to ModelLoader argument labels. This blocks `swift build`/`swift test` for literally every target (even the library alone) regardless of my fix here. I'll patch the vendored copy only inside the gitignored `.build/checkouts` tree (never committed) purely so I can verify my own change compiles past this unrelated blocker, and will file a separate task to track the real fix (which belongs in the mlx-swift-lm fork).
  timestamp: 2026-07-07T13:27:05.980818+00:00
- actor: claude-code
  id: 01kwyd21xvxw0fs4pnvrczfzr6
  text: |-
    Done. Fixed the argument-label mismatches everywhere they occurred (this reached far more files than the two named in the description, since the acceptance criteria's "(and similar)" call-site wording turned out to matter):

    **ModelLoader / LoadedEmbeddingContainer stub conformances relabeled** (positional/underscore first params → the protocol's exact labels) in:
    - Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift (`PhaseRecordingLoader`, `DownloadObservingLoader` — including their internal delegation calls to the wrapped loader)
    - Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift, GuidedGenerationTests.swift, ExamplesTests.swift, ForkConcurrencyTests.swift, ToolIntegrationTests.swift, GuidedShapesTests.swift, MergedAndRedactionTests.swift, ResolveTests.swift (including a private `stubLoad` helper that itself takes `ref:` labeled and was called positionally), SessionChokepointTests.swift, TranscriptNestingTests.swift

    Concretely: `loadLLM(_ ref:` → `loadLLM(ref:`, `loadEmbedder(_ ref:` → `loadEmbedder(ref:`, `preload(_ container:` → `preload(container:`, `evict(_ container:` → `evict(container:`, `embed(_ texts:` → `embed(texts:`.

    **Call sites relabeled** to match: every `router.resolve(X, reporting:)` → `router.resolve(profile: X, reporting:)` (dozens of occurrences), every `.embed([...])` → `.embed(texts: [...])` on `RoutedEmbedder`/`EmbedTool`. While fixing these, the same class of bug turned up one level up the call chain and I fixed it too since it was blocking the same files: `RoutedLLM.makeGuidedSession(grammar:...)` calls that passed the grammar positionally, and one `SummarizeTool.summarize(text:)` call that did the same — both are the identical "protocol/method gained a label, call site didn't" pattern, just on different symbols in the same files I was already touching.

    No production code under Sources/ or Examples/ was touched — this was purely test-target stub signatures and call sites.

    **Root cause confirmed**: commits 825f7c7/e067f54/ac1e95c added explicit external labels to `ModelLoader`/`LoadedEmbeddingContainer`/`Router.resolve` (and, transitively, `makeGuidedSession`/`summarize`) but never touched the test-target conformances/call-sites, so the stubs stopped satisfying their protocols and every call site using the old positional shape stopped compiling.

    **Verification**: A repo-wide diagnostics sweep of `Tests/**/*.swift` after my fix shows zero remaining argument-label errors. The only diagnostics left anywhere are 13 occurrences of one specific, pre-existing, out-of-scope error — a stub's `LoadedLLMContainer` conformance still implements the *old* `respond`/`streamResponse` shape instead of the new `makeSession(instructions:)` the protocol now requires — which is exactly the scope of the separate, currently-blocked task `qzwtm1m` ("Update all test stubs to implement the LanguageModelSessionBackend factory seam"), plus two harmless "no async operations in await" warnings that are pre-existing artifacts of that same unrelated shape mismatch. I left those untouched per this task's own "modulo any other in-flight, separately-tracked stub work" acceptance criteria.

    **Unrelated environmental blocker discovered and worked around only for local verification**: `swift build`/`swift test` in this sandbox additionally fail before ever reaching FoundationModelsRouter's own sources, because the vendored `mlx-swift-lm` dependency (`.build/checkouts/mlx-swift-lm`, not part of this git repo) pattern-matches `GenerationOptions.SamplingMode.Kind` cases `.top`/`.nucleus`, but the current Xcode 27 beta (Swift 6.4) FoundationModels SDK renamed them to `.randomTopK`/`.randomProbabilityThreshold` (confirmed by reading the SDK's `.swiftinterface` directly). The pinned mlx-swift-lm revision is already at its branch HEAD, so this isn't a stale-pin issue — it's a genuine SDK/toolchain incompatibility that belongs in a different repo. I patched the vendored copy locally, purely inside the gitignored `.build/` tree (never committed, not part of this diff), only so I could get a real compiler run past it to verify my actual fix. With that local-only patch in place: `swift build --target FoundationModelsRouter` is green, `swift build --build-tests` proceeds through the library, the `MultiModelGeneration` executable, and into both test targets, failing only on the two `LoadedLLMContainer` conformance errors described above (ProfileLifecycleTests.swift, ToolIntegrationTests.swift — first two files SwiftPM happened to compile in that pass; the diagnostics sweep confirms 13 such occurrences total across the suite, all the same root cause).

    Filed as a new blocking discovery — recommend a follow-up task to either bump the toolchain pin or patch the mlx-swift-lm fork upstream for `.randomTopK`/`.randomProbabilityThreshold`.

    Adversarial double-check (subagent) reviewed the full diff against the real protocol/method declarations and returned PASS: all relabeling verified correct, no positional reversions or error suppression, no production code touched, and a fresh whole-tree grep for leftover unlabeled patterns returned zero hits.

    Leaving this in `doing` per the implement workflow — ready for `/review`.
  timestamp: 2026-07-07T13:42:39.803719+00:00
position_column: done
position_ordinal: a780
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
