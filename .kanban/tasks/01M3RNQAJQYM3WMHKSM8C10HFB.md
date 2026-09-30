---
comments:
- actor: claude-code
  id: 01m3rss38sqqsgvqpt5qbm9jjz
  text: |-
    Research:
    - Extras is at b553bdf in the root and IntegrationTests checkouts. `MLXModelLoader(tokenizerLoader:)` is public. Its LLM load uses the same capabilities (.guidedGeneration, .toolCalling, .reasoning) and the same default revision ("main") as the private copy in RealModelContainer. Thus `pinnedModelCapabilities`, `pinnedModelRevision` and `loadPinned` can go.
    - `LiveModelLoader.init(reporting:modelLoader:)` is internal. RealModelSupport imports the Router without @testable, so the init must be `package` (enough: RealModelSupport is in the same package). Decision: `package`, not `public`. A public init adds API scope that no consumer asks for.
    - RealModelSupport does not link the FoundationModelsExtras product. It must link it to name `MLXModelLoader`.
    - `MLXLanguageModel.evictAll()` stays: the MLX model cache is still keyed by model id, so a cached unpinned container can still defeat a pin.
    - CompactionEvalRealModelContainer already loads through `LiveModelLoader()` and makes no MLXLanguageModel. It takes no date pin, so it needs no change.
    - Tests/FoundationModelsRouterTests/Helpers/UnloadableMLXModel.swift makes an MLXLanguageModel whose load always fails. It is a unit-test fake, not test support, and MLXModelLoader cannot give a model that has no weights. It stays.
    - The card says `swift package update` and push. The dispatcher told me not to update and not to push. Extras is already resolved at b553bdf. The CI box stays open.
  timestamp: 2026-09-30T09:19:23.929656+00:00
- actor: claude-code
  id: 01m3rvs0nepcm5d8db6y44fd36
  text: |-
    Implementation landed.
    - RED: `swift build --target FoundationModelsRouterRealModelSupport` failed with "extra argument 'modelLoader' in call", because `LiveModelLoader.init(reporting:modelLoader:)` was internal.
    - GREEN: the init is `package` now. The same build completes.
    - RealModelContainer: a new private `makeLoader(chatTemplateDate:)` gives `LiveModelLoader()` with no pin. With a pin, it gives `LiveModelLoader(reporting:modelLoader: MLXModelLoader(tokenizerLoader: PinnedDateTokenizerLoader(...)))`. `loadPinned`, `pinnedModelCapabilities` and `pinnedModelRevision` are deleted. `MLXLanguageModel.evictAll()` stays before a pinned load. The file imports only `struct FoundationModelsExtras.MLXModelLoader` from Extras, and no longer imports HuggingFace.
    - Package.swift: RealModelSupport links the FoundationModelsExtras product and `Tokenizers` only. The `HuggingFace` product and the `swift-huggingface` package dependency are deleted, because only the deleted pinned path used `#hubDownloader()` and `HubCache`. Package.resolved did not change.
    - Not changed: CompactionEvalRealModelContainer (it already loads through `LiveModelLoader()`), and the unit-test fake UnloadableMLXModel (it is in the unit test target, not in a test support target).
    - Follow-up: ^f3yekaf removes the unused `hubProducts` from the IntegrationTests manifest.
    - Open: the box "CI is green on the pushed commit". The dispatcher said not to commit, push or run `swift package update`.

    ### implement — changed
    - evidence: 3 files — Package.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift. `swift test`: 1427 tests in 178 suites passed (2 known issues from before), plus 23 and 19. `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests`: 49 tests in 22 suites passed, including the pinned-date suite (^g8rywv2, 2 tests). `--filter FoundationModelsRouterEvalIntegrationTests`: 1 test passed. The only warning is the known mlx-swift_Cmlx.bundle "missing creator" warning.
    - next: review, then commit and push; the CI box needs the pushed commit.
  timestamp: 2026-09-30T09:54:18.414057+00:00
position_column: doing
position_ordinal: '80'
title: RealModelContainer loads through MLXModelLoader(tokenizerLoader:)
---
**Wait for:** FoundationModelsExtras task 01M3RNQ6K5MBEN68C62VGNWW4Y ("MLXModelLoader takes an optional tokenizer loader") on the Extras board: done and pushed.

## What
- `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`: for pinned chat-template date loads, use `LiveModelLoader(reporting:modelLoader: MLXModelLoader(tokenizerLoader: PinnedDateTokenizerLoader(...)))` in place of making its own `MLXLanguageModel`.
- Delete the code that only that path used.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [x] No Router source or test support constructs an `MLXLanguageModel`.
- [x] The pinned-date real-model tests still get the pinned date in the chat template.
- [ ] CI is green on the pushed commit.

## Tests
- [x] The existing real-model tests that use the pinned date pass.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool