---
assignees:
- claude-code
depends_on:
- 01M1RRG1E1EVTDZVRQ919T04M2
position_column: todo
position_ordinal: '8780'
title: 'Sampling mode, step B: remove the stored mode from the container and from LiveModelLoader'
---
Plan: `model-pool.md` §2.5 step B.

## What
Step A gave every `makeSession` a `samplingMode:` parameter. This step removes the stored copy, so a shared container carries no decoding strategy.

- `MLXFoundationModelsContainer` drops `samplingMode`. `LiveModelLoader.init` drops its `samplingMode:` parameter and property (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`).
- The mode reaches `LiveModelLoader` today through two helpers that build no `Router` and return a bare container: `RealModelContainer.load(ref:context:samplingMode:chatTemplateDate:)` in `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`, and `CompactionEvalRealModelContainer.load(...)` under `IntegrationTests/Tests/.../Support/`. Keep their `samplingMode:` parameter, but store it on the helper and pass it into every `makeSession(...samplingMode:)` call the helper or its callers make. The argmax pin is what makes the gated suites repeatable, so no site may lose it.
- Convert each direct `makeSession` call on a bare container. Known sites, all under `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/` unless stated: `CancelledGenerationTeardownIntegrationTests.swift`, `LanguageModelSessionBackendTests.swift`, `RealToolTurnComparisonTests.swift`, `SessionTreeRestorationIntegrationTests.swift`, `CompactionRoundTripIntegrationTests.swift`, `CompactionSmokeIntegrationTests.swift`, `RecordedTranscriptCompactionIntegrationTests.swift`, `AutoCompactionTriggerIntegrationTests.swift`, `PinnedChatTemplateDateIntegrationTests.swift`, and the two eval runners. Search with `rg -n 'makeSession\(' IntegrationTests Tests/FoundationModelsRouterRealModelSupport` for the full list.
- `Examples/CompactionDemo/main.swift` passes the mode to `Router(samplingMode:)` instead of the loader. `Examples/MultiModelGeneration` names no mode and needs no change.
- Fix the DocC link ``MLXFoundationModelsContainer/samplingMode`` in `RealToolTurnComparisonTests.swift`, and rewrite the rationale comment in `GatedEvalSerialGate.swift` ("one container cannot carry two strategies") to state the new rule: the mode is per call, and the gate stays for the GPU, not for the mode.

## Acceptance Criteria
- [ ] `rg -n samplingMode Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` finds it only on `makeSession` parameters and on the backend, never as a stored property of the container or the loader.
- [ ] Every gated suite still pins `.greedy` where it did before; `rg -n 'makeSession\(' IntegrationTests Tests/FoundationModelsRouterRealModelSupport` shows a `samplingMode:` argument at each site that had a greedy loader before.
- [ ] Both examples build. `swift test` and `swift test --package-path IntegrationTests` are green.

## Tests
- [ ] Existing gated suites pass unchanged in outcome: `swift test --package-path IntegrationTests` → all pass.
- [ ] `swift build --product CompactionDemo` and `swift build --product MultiModelGeneration` → build.
- [ ] `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router-api