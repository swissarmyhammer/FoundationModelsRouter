---
comments:
- actor: claude-code
  id: 01m3rern4114fgf2fnz3kytvr8
  text: |-
    Research done.
    - Extras 0b487c6: `MLXModelLoader.load(key:progressHandler:)` gives an `MLXLanguageModel` (preloaded, capabilities guided/tool/reasoning) for `.llm`. It makes its own `#hubDownloader()` and `#huggingFaceTokenizerLoader()`. It has NO parameter for a tokenizer loader.
    - `PooledSession` casts `hold.container as? any LanguageModel`. The Extras contract: "each loader of an LLM key must return a LanguageModel". The Router pool entry of a Router load is an `MLXFoundationModelsContainer`, which is not a `LanguageModel`. Thus a `PooledModel` after a resolve throws `notALanguageModel` now. In the other order, `ModelHold.generationContainer()` throws `notAGenerationContainer` for a bare `MLXLanguageModel`.
    - Design: `MLXFoundationModelsContainer` conforms to `LanguageModel` (it forwards to its `model` through `ExecutorPassthrough`). `generationContainer()` becomes async and wraps a bare `MLXLanguageModel` hold. One package helper wraps a loaded `MLXLanguageModel` (tokenizer counter + context window from config.json); `LiveModelLoader`, `generationContainer()` and the test support use it.
    - `LiveModelLoader`: one injected `PooledModelLoader` (MLXModelLoader by default) for both roles. The public init loses `downloader`, `tokenizerLoader` and `weightsLocation` (only the old path used them). The progress helper of ^jkfp5fp maps both roles.
    - Pinned chat template date: `RealModelContainer` (test support) gives `PinnedDateTokenizerLoader` to `LiveModelLoader`. MLXModelLoader cannot take it. The test support will build its own `MLXLanguageModel` with the pinned tokenizer and wrap it with the package helper. The Router library then constructs no `MLXLanguageModel`.
    - Keep `import MLXVLM` / `MLXLLM` in the Router: the model factory registry of `loadModelContainer` (now called in Extras) finds the VLM factory only when the binary links MLXVLM. Extras does not import MLXVLM.
  timestamp: 2026-09-30T06:06:55.105402+00:00
- actor: claude-code
  id: 01m3rfk53e82kz1zjx1jm85b06
  text: |-
    Implementation landed in the library; unit tests green (SlotPoolLoaderTests, ExtrasPoolResolveTests, GenerationQueueTests: 25 tests pass).
    - RED seen: `PooledModel(ref:pool:).session()` after a resolve threw `notALanguageModel(... containerType: "MLXFoundationModelsContainer")`. GREEN after `MLXFoundationModelsContainer: FoundationModels.LanguageModel` (new file `Resolution/MLXFoundationModelsContainerPooling.swift`). Note: `LanguageModel` is ambiguous with MLXLMCommon; spell `FoundationModels.LanguageModel`.
    - What did not work: a unit test that wraps an `MLXLanguageModel` (even one whose load closure throws) crashes the test process: `MLXLanguageModel.loadContainer()` sets `MLX.Memory.cacheLimit` before it calls the load closure, and that needs the metal library ("Failed to load the default metallib"). Thus the unit tests cover the wrap only through the not-an-MLXLanguageModel path; the real wrap and the PooledModel-first order are covered in the integration package.
    - Deleted `LiveModelLoaderTests.swift`: it tested only `mapProgress(_:)`, which only the old load path used.
  timestamp: 2026-09-30T06:21:23.438077+00:00
- actor: claude-code
  id: 01m3rhjt09q7dbss6zkgx33sd1
  text: |-
    Implementation complete; all tests green.
    - Library: `LiveModelLoader` loads both roles through one injected `PooledModelLoader` (`MLXModelLoader()` by default; internal `init(reporting:modelLoader:)` for tests). Public init is now `LiveModelLoader(reporting:)`; `downloader`, `tokenizerLoader`, `weightsLocation`, `mapProgress(_:)`, `handler(reporting:)`, `configuration(for:)` and `defaultRevision` are deleted. New `LiveModelLoaderError.notAnMLXLanguageModel`; a failed generation load gives the container back to the model loader. Evict of a generation container goes through the model loader.
    - New file `Resolution/MLXFoundationModelsContainerPooling.swift`: `MLXFoundationModelsContainer.make(wrapping:repo:)` (tokenizer counter + context window, moved from LiveModelLoader) and `MLXFoundationModelsContainer: FoundationModels.LanguageModel` (forwards to its model through `ExecutorPassthrough`). `ModelHold.generationContainer()` is async now and wraps a bare `MLXLanguageModel` hold, so the sharing works in both orders.
    - Progress: one helper `downloadProgress(of:)` maps `ModelLoadProgress.downloading(fraction:)` (the values that `ModelPool.progress(for:)` carries) to `DownloadProgress` on `LiveModelLoader.progressScale` (renamed from `embeddingProgressScale`) for both roles. The resolve keeps its downloading → loading → ready slot states. The router does not subscribe to the pool stream itself: a router load does not feed that stream with download fractions (SlotPoolLoader does not forward a ModelLoadProgress handler), so a subscription would add nothing over the loader callback.
    - Test support: `RealModelContainer` loads through `LiveModelLoader()`; only a pinned-date load makes its own `MLXLanguageModel` with `PinnedDateTokenizerLoader`, because `MLXModelLoader` takes no tokenizer loader (Extras gap; possible follow-up: a tokenizer-loader parameter on `MLXModelLoader`).
    - Callers updated: Examples (2), Tools/RecordCompactionFixture, IntegrationTests (IntegrationTests, PromptCacheBudget, CrossRouterPool, CompactionEvalRealModelContainer), README install section, Package.swift (hub products only on RealModelSupport now).
    - Not done on instruction of the orchestrator: `swift package update`, commit, push, CI. The "CI is green on the pushed commit" box stays open.
  timestamp: 2026-09-30T06:56:09.225094+00:00
- actor: claude-code
  id: 01m3rhjz0225f9zpe1xje6aktv
  text: |-
    ### implement — changed
    - evidence: `swift test`: 1424 tests in 178 suites pass (2 known issues by design) + 22 + 19; `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests`: 49 tests in 22 suites pass (1070 s); `--filter FoundationModelsRouterEvalIntegrationTests`: 1 test passes. Only warning: the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line, which comes from the mlx bundle, not from this change. 20 files: Sources/FoundationModelsRouter/Resolution/{LiveModelLoader,SlotPoolLoader,MLXFoundationModelsContainerPooling(new)}.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/{SlotPoolLoaderTests,ExtrasPoolResolveTests,GenerationQueueTests,Helpers/UnloadableMLXModel(new)}.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift (deleted), Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift, IntegrationTests/.../{CrossRouterPoolIntegrationTests,IntegrationTests,PromptCacheBudgetIntegrationTests,Support/CompactionEvalRealModelContainer}.swift, Examples/{MultiModelGeneration,CompactionDemo}/main.swift, Tools/RecordCompactionFixture/main.swift, Package.swift, README.md
    - next: review
  timestamp: 2026-09-30T06:56:14.338519+00:00
- actor: claude-code
  id: 01m3rja55ayvdpvfj0b0th1tva
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (ce67176); 2 findings (2 confirmed, 1 refuted) — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:841, Tools/RecordCompactionFixture/main.swift:134. Five code-hygiene Swift rules found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift (the commit deleted it or moved it).
    - next: implement the two open items in the "Review Findings (2026-09-30 00:57)" section, then review again.
  timestamp: 2026-09-30T07:08:54.314437+00:00
- actor: claude-code
  id: 01m3rjanzrb3vnzf1nscq5fcrh
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 21 files
    - test: green — swift test 1424 passed; IntegrationTests 49 + 1 passed (run by implement)
    - commit: ce67176
    - review: findings — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:841, Tools/RecordCompactionFixture/main.swift:134
  timestamp: 2026-09-30T07:09:11.544459+00:00
- actor: claude-code
  id: 01m3rjrq79ab4by4g53485jnnq
  text: |-
    Review findings fixed.
    - Finding 1 (swift/access-control): `LiveModelLoaderError` and its `errorDescription` are `public` now. The same cause in the file: `ModelLoaderError` was `internal`, but the public `UnconfiguredModelLoader` throws it and links it in its docs. It is `public` now. The public docs of `LiveModelLoader` also linked non-public symbols: ``MLXFoundationModelsContainer`` (package) and ``LoadedPooledEmbedding`` (internal) in the type doc and in `load(_:)`, and ``CancellableWait`` (package) in `loadLLM` and `loadEmbedder`. These links are now plain words. The top `//` comment and the private `loadThroughModelLoader` doc keep their links, because they are not public docs.
    - New test `Tests/FoundationModelsRouterPublicSurfaceTests/LoaderErrorPublicSurfaceTests.swift` (plain import, no `@testable`). RED: "cannot find type 'LiveModelLoaderError' in scope" and "cannot find 'ModelLoaderError' in scope". GREEN after the change.
    - Finding 2 (swift/initialization): Tools/RecordCompactionFixture, Examples/CompactionDemo and Examples/MultiModelGeneration call `LiveModelLoader(reporting: { _ in })`, with a comment that tells why the value is dropped: a router load reports to the callback of its resolve. The Package.swift comments name `LiveModelLoader(reporting:)` now.
    - Not changed, because they are out of the scope that the orchestrator gave (Tools and Examples): `LiveModelLoader()` in README.md, Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift and the IntegrationTests package. The public init keeps its default `{ _ in }`, so these still compile.
  timestamp: 2026-09-30T07:16:51.561127+00:00
- actor: claude-code
  id: 01m3rjrtn75jv9gkh49p7p9snz
  text: |-
    ### implement — changed
    - evidence: `swift test`: 1424 tests in 178 suites pass (2 known issues by design), 23 tests in 11 suites pass (public surface, was 22), 19 tests in 3 suites pass. `swift build --product RecordCompactionFixture`, `--product CompactionDemo` and `--product MultiModelGeneration`: Build complete. The only warning is the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line, which does not come from a changed file. 7 files: Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterPublicSurfaceTests/LoaderErrorPublicSurfaceTests.swift (new), Tools/RecordCompactionFixture/main.swift, Examples/CompactionDemo/main.swift, Examples/MultiModelGeneration/main.swift, Package.swift (comments only), .kanban task (findings checked).
    - next: review
  timestamp: 2026-09-30T07:16:55.079237+00:00
- actor: claude-code
  id: 01m3rk0kj2p8fjavvy059hza9s
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (afd9b5a): 0 findings (6 files reviewed, 7 attempted, 0 failed). The 2 prior findings are checked.
    - next: The task is in done. The acceptance criterion "CI is green on the pushed commit" is not checked. Examine CI after the push.
  timestamp: 2026-09-30T07:21:09.954165+00:00
depends_on:
- 01M3QMDDGWZ7CRAE1P3JKFP5FP
position_column: done
position_ordinal: ffffffb980
title: Generation models load through the Extras MLXModelLoader; map pool progress to resolution progress
---
**Wait for:** FoundationModelsExtras tasks 01M3QMD6V09WGE7MJDV483VHBG ("Built-in MLX loader in the core…") and 01M3QMD7BY8SYK3EGAMG8M6X1Y ("Load progress stream on the model pool") on the Extras board: done and pushed.

## What
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: `loadGeneration` gets its `MLXLanguageModel` from `MLXModelLoader().load(key)` in place of making it; the Router wraps it in `MLXFoundationModelsContainer` as now (queue, token counter, context window stay Router code).
- Download progress: map `ModelPool.progress(for:)` to `DownloadProgress` / `ResolutionProgress`, so resolve still reports downloading → loading → ready.
- Keep `acquire(_:footprintBytes:sessionBytes:loader:)` with the Router sizing and admission (`SlotPoolLoader`, `PromptCacheSizing`).
- Delete the Router code that only the old load path used.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [x] The Router has no code that constructs an `MLXLanguageModel`.
- [x] A Router resolve and a `PooledModel` with the same name in one process share one resident model.
- [x] Resolution progress still reports downloading, loading and ready.
- [ ] CI is green on the pushed commit.

## Tests
- [x] `Tests/FoundationModelsRouterTests/ExtrasPoolResolveTests.swift`: resolve, then `PooledModel(ref: sameName).session` does not load again.
- [x] A resolution-progress test with a test loader that reports progress.
- [x] `IntegrationTests/.../CrossRouterPoolIntegrationTests.swift`: real resolve + `PooledModel` on one name share one resident model.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool

## Review Findings (2026-09-30 00:57)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift, so its declarations are unread

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:841` `swift/access-control` — Public method `loadLLM` (line 938) documents that it throws `LiveModelLoaderError/notAnMLXLanguageModel(...)` (line 936) with a DocC symbol link, but the error type is defined with implicit `internal` access. Public methods must throw public error types so callers can catch and reference them, and DocC symbol links require the referenced type to be public. Add `public` modifier: `public enum LiveModelLoaderError: Error, Equatable, LocalizedError {`.
- [x] `Tools/RecordCompactionFixture/main.swift:134` `swift/initialization` — `LiveModelLoader()` is called with no arguments, but the breaking change specifies the new init signature is `LiveModelLoader(reporting:)`, which requires a reporting parameter. Pass the required `reporting` parameter: `loader: LiveModelLoader(reporting: { _ in })`.
