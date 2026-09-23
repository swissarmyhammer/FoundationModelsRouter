---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37q1xdebenh551yfs7xn453
  text: |-
    ### decision (2026-09-23): no bound, decided in Router

    The owner's rule for limits is "the default being that we should not have bounds". Decision: when a caller names no ceiling, the router backend (`MLXFoundationModelsSessionBackend`, `Resolution/LiveModelLoader.swift`) sends the model's own window as `maximumResponseTokens`. It does not send `nil`. The window is the model's `nativeMaxContext` from `config.json`, which the loader already reads, or the resolved context the backend was made with. The engine's `defaultMaxTokens = 4096` then never applies to a Router call. The fork `mlx-swift-lm` does not change. It is another repo, and the literal stays there for direct callers of the engine.

    Do this:
    1. Find where the backend has the model's window, or pass it in when the backend is made. `makeGenerationOptions(maxTokens:)` uses `maxTokens ?? window`.
    2. Add no new number. The window comes from the model.
    3. Unit test: a backend call with `maxTokens: nil` sends the window, not `nil`. A call with a ceiling sends that ceiling.
    4. Update the docs from ^wn4zecb that say `nil` goes to the engine.
  timestamp: 2026-09-23T18:04:41.774689+00:00
- actor: claude-code
  id: 01m37q8fhskjpqjs949yek3z0c
  text: |-
    ### Research and design choices
    - Choice 1: the window is the native max context of `config.json` in the local model directory. `LiveModelLoader.loadLLM` reads it after the load. The loaded `ModelContainer.configuration.id` is `.directory(modelDirectory)` (the fork's `LLMModelFactory._load` and `VLMModelFactory` build it so). The `context` argument of `loadLLM` is not used, because `ModelLoader` says it is advisory and one container serves every working context.
    - Choice 2: `RepoMetadata.nativeMaxContext(configJSON:repo:)` is new. It reuses the same sizing source and the same field order as `init(raw:repo:)`, through a new private `sizingSource(configJSON:)` that `init(raw:repo:)` also calls. No new number.
    - Choice 3: a load whose `config.json` has no positive context-length field now throws `RepoMetadataError.metadataUnavailable`. There is no fallback number.
    - Choice 4: `MLXFoundationModelsContainer.contextWindow` and `MLXFoundationModelsSessionBackend.contextWindow` (required init argument). `makeGenerationOptions(maxTokens:)` sends `maxTokens ?? contextWindow`. Forks and `replacingTranscript` keep the window.
    - Choice 5: test helper `LiveBackendContainer.contextWindow` defaults to `ScriptedSessionContext.tokens` (test-only fixture constant).
    - The full validator dump for `.swift` is 754k characters; it was not read whole. The review step enforces the rules.
  timestamp: 2026-09-23T18:08:16.953797+00:00
- actor: claude-code
  id: 01m37qbd4ahgdka80vtxcd4rrh
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/Helpers/LiveBackendContainer.swift, Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift, Tests/FoundationModelsRouterTests/RepoMetadataTests.swift. `swift test`: 1333 tests in 150 suites passed (2 known issues, expected); 1 test in 1 suite passed; 19 tests in 3 suites passed. `swift build --build-tests --package-path IntegrationTests`: exit 0. `swift test --package-path IntegrationTests --filter Qwen38CompactionIntegrationTests`: 3 tests in 1 suite passed (the live load read the window from config.json).
    - next: commit, then review.
  timestamp: 2026-09-23T18:09:52.778448+00:00
- actor: claude-code
  id: 01m37qgr7a25vx2vc7pa79c17m
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 0bb3bb5 — 0 findings, 0 confirmed, 0 refuted; 6 files reviewed, 2 .kanban files excluded by .reviewignore.
    - next: done.

    ### finish iteration 1 — done
    - commits: 0bb3bb5 feat(session): send the window of the model when a call names no ceiling
    - `swift test`: Test run with 1333 tests in 150 suites passed (2 known issues, expected); Test run with 1 test in 1 suite passed; Test run with 19 tests in 3 suites passed.
    - `swift build --build-tests --package-path IntegrationTests`: exit 0.
    - `swift test --package-path IntegrationTests --filter Qwen38CompactionIntegrationTests`: Test run with 3 tests in 1 suite passed after 29.520 seconds.
    - The fork mlx-swift-lm did not change. Its `defaultMaxTokens = 4096` stays for direct callers of the engine and never applies to a Router call.
  timestamp: 2026-09-23T18:12:47.978252+00:00
position_column: done
position_ordinal: fffffa80
title: Decide the 4096 defaultMaxTokens of the mlx-swift-lm executor
---
## Finding (from ^wn4zecb)

The fork `swissarmyhammer/mlx-swift-lm`, file `Libraries/MLXFoundationModels/MLXLanguageModel.swift:843`, has `private static let defaultMaxTokens = 4096`. The executor uses it when `GenerationOptions.maximumResponseTokens` is `nil` (lines 1777, 2126, 2311, 2404, 2512).

After ^wn4zecb, the router backend sends `nil` when the caller names no ceiling and the session gives no context. A routed session always gives its context (the window), so this path is only a direct backend call.

## Question for the owner

This is an invented limit in the dependency. Keep it, remove it in the fork (decode to the window of the model), or make the backend always send a number. The owner decides. #limits