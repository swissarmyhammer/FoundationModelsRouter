---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1s1b8q8awrphde3kbt7pt4w
  text: |-
    ### implement — changed
    - evidence: 26 files. Library: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` (the container and the loader store no `samplingMode`; each `makeSession(...samplingMode:)` gives the mode to the backend). Support: `RealModelContainer` is a struct that keeps `container` and `samplingMode`; `RealModelHarness.make` takes `samplingMode:`; `CompactionFold` and `CountingBlankSlateSummarizer` take the struct and pass the mode. Eval: `CompactionEvalRealModelContainer` is a struct with the same shape; both runners pass the mode; `GatedEvalSerialGate` states the new rule. Suites: 15 gated suites pass `loaded.samplingMode` at each bare `makeSession` site or to the harness. Examples and tools: `CompactionDemo` and `RecordCompactionFixture` pass the mode to `Router(samplingMode:)`. Unit test: `RealModelHarnessTests` has a new test that holds the mode on both generation handles.
    - RED: `swift build --build-tests` failed at `RealModelHarnessTests.swift:199` with `extra argument 'samplingMode' in call`.
    - GREEN: `swift build --build-tests`, `swift build --package-path IntegrationTests --build-tests`, `swift build --product CompactionDemo`, `swift build --product MultiModelGeneration` all exit 0 with no new warning.
    - Discovery: the `files` tool option `replace_all` changed one site only in this environment. Each site got its own edit.
    - next: test
  timestamp: 2026-09-05T15:00:15.720441+00:00
- actor: claude-code
  id: 01m1s21sc7e64cerpc6emsh5sg
  text: |-
    ### test — green
    - evidence: `swift test` → 1231 tests in 133 suites passed (2 known issues, both pre-existing `withKnownIssue` tests) and 83 tests in 10 suites passed, exit 0. `swift build --package-path IntegrationTests --build-tests` → exit 0, no new warning. `swift test --package-path IntegrationTests` → 34 tests in 17 suites passed after 616.8 s, and 2 tests in 2 suites passed after 71.8 s, exit 0. `swift build --product CompactionDemo` and `swift build --product MultiModelGeneration` → exit 0. The one warning in every build, `missing creator for mutated node`, is the SwiftPM bundle warning that the RED run also printed; it is not new.
    - next: commit
  timestamp: 2026-09-05T15:12:33.671622+00:00
- actor: claude-code
  id: 01m1s7pb6drabj3cnc8ffynvaz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 598e00f → 0 findings, 0 confirmed, 0 refuted, 21 review tasks attempted, 0 failed, 0 skipped. 25 files reviewed; 2 `.kanban/` files excluded by `.reviewignore`. A previous run reported 6 of 21 review tasks failed; that run was not a review and was not written to the card.
    - next: done
  timestamp: 2026-09-05T16:51:10.157104+00:00
- actor: claude-code
  id: 01m1s7pfz2bpx74bpr04sxvwmy
  text: |-
    ### finish iteration 1 — review clean, card moved to done
    - implement: changed — 26 files: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`, `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`, `RealModelHarness`, `CompactionFold`, `CountingBlankSlateSummarizer`, `RealModelHarnessTests.swift`, `CompactionEvalRealModelContainer`, both eval runners, `GatedEvalSerialGate.swift`, 15 gated suites, `Examples/CompactionDemo/main.swift`, `RecordCompactionFixture`
    - test: green — `swift test` → 1231 tests in 133 suites and 83 tests in 10 suites, 0 failures; `swift test --package-path IntegrationTests` → 34 tests in 17 suites and 2 tests in 2 suites, 0 failures; both examples build
    - commit: 598e00f
    - review: clean — 0 findings, 21 attempted, 0 failed
  timestamp: 2026-09-05T16:51:15.042948+00:00
depends_on:
- 01M1RRG1E1EVTDZVRQ919T04M2
position_column: done
position_ordinal: ffffc980
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