---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rz2p9xcnnwq3wktrpez5jc
  text: |-
    ### research — step A of §2.5

    Call sites that make a backend from a container in `Sources/`:
    - `RoutedLLM.swift:154` — the root session: `container.makeSession(instructions:tools:)`. The handle has the mode after this card, so it passes `samplingMode`.
    - `Recording/SessionTreeRestoration.swift:364` — the transcript-seeded session: `routedLLM.container.makeSession(transcript:tools:)`. `routedLLM` is a `RoutedLLM`, so it passes `routedLLM.samplingMode`.
    - `Session/RoutedSessionActorCompaction.swift:145` — the flash summarizer of the automatic fold: `profile.flash.container.makeSession(instructions: nil)`. It passes `profile.flash.samplingMode`.
    - `Tools.swift:37` calls `RoutedLLM.makeSession`, not the container. No change.

    Default forwarding. Thirteen test stubs override the old `tools:` signatures (`SessionRestorationTests`, `ToolOutputCappingTests`, `SessionOutboxToolWiringTests`, `ScriptedToolCallingModel`, and more) to capture the tools. So each new default extension forwards to its own old counterpart and drops the mode: `(instructions:samplingMode:)` → `(instructions:)`, `(instructions:tools:samplingMode:)` → `(instructions:tools:)`, and the same for the two transcript signatures. A default that forwarded a tools signature to a no-tools signature would skip those stubs.

    The only `compact()` path that builds a backend from a container is the automatic fold's flash tier (`foldThroughTiers`). The caller-driven `compact(prompt:budget:)` folds on the session's own live backend. So the compaction test drives the automatic fold with `AutoCompactionFixtures.makeTriggeredSession` and reads the mode the flash container received.

    `GenerationOptions.SamplingMode` is `Equatable` in the macOS 27 SDK, so a test can compare recorded modes directly.

    Test design: the shared `ConfiguredLLMContainer` (`Helpers/AutoCompactionFixtures.swift`) records the mode each mode-carrying `makeSession` receives. Its old signatures record nothing, so a router that calls an old signature leaves a gap in the recorded list. One stub serves both new tests: the auto-compaction fixture already vends it for the flash slot, and `ResidencyFixtures.makeRouter(llmContainer:)` can vend it for both routers of the cross-router test.
  timestamp: 2026-09-05T14:20:37.565780+00:00
- actor: claude-code
  id: 01m1rzm7q5950tces75we7hwbs
  text: |-
    ### implement — changed
    - evidence: 14 files. Sources: `Resolution/ModelLoader.swift` (four `makeSession(...samplingMode:)` requirements; each default forwards to its own old counterpart), `Resolution/LiveModelLoader.swift` (`MLXFoundationModelsContainer` implements the four; `nil` falls back to the stored `samplingMode` through `resolvedSamplingMode(_:)`), `LanguageModelProfile.swift` (`RoutedModel.samplingMode`, init parameter with default `nil`), `Router.swift` (`samplingMode` property, `init(samplingMode:)`, `makeRoutedModel` passes it), `RoutedLLM.swift:156`, `Recording/SessionTreeRestoration.swift:364`, `Session/RoutedSessionActorCompaction.swift:145` (the three container call sites pass the mode). Tests: `Helpers/AutoCompactionFixtures.swift` (`ConfiguredLLMContainer.receivedSamplingModes`, `makeTriggeredSession(samplingMode:)`), `Helpers/RouterTestFixtures.swift` and `Helpers/ResidencyStubs.swift` (`makeRouter(samplingMode:)`), `CrossRouterResidencyTests.swift` (`makePair` gains the two modes and `llmContainer`; new test `eachRouterPassesItsOwnSamplingModeToTheSharedContainer`), `RoutedSessionCompactTests.swift` (new test `autoFoldFlashSummarizerReceivesTheRoutersSamplingMode`), `AutoCompactionTests.swift` and `CompactionTracingTests.swift` (DocC link to the fixture's new signature).
    - TDD: RED was `swift build --build-tests` → `extra argument 'samplingMode' in call` at `ResidencyStubs.swift:278` and `RouterTestFixtures.swift:178`. GREEN was `swift test --filter "CrossRouterResidencyTests|RoutedSessionCompactTests"` → 22 tests in 2 suites passed.
    - next: `/test` over the whole root target.
  timestamp: 2026-09-05T14:30:12.453090+00:00
- actor: claude-code
  id: 01m1rzne75embr8sx4wjjr774f
  text: |-
    ### test — green
    - evidence: `swift test` → 1230 tests in 133 suites passed (Swift Testing) and 83 tests in 10 suites passed; 0 failures, 0 skipped. The 2 known issues are the pre-existing `withKnownIssue` blocks at `BoundedWaitTests.swift:32` and `RealModelHarnessTests.swift:248`. The one `warning:` line is SwiftPM's `missing creator for mutated node` for the `mlx-swift_Cmlx.bundle` product; it printed on the RED run before any production edit and names no source file.
    - next: `/commit` (local only).
  timestamp: 2026-09-05T14:30:51.877570+00:00
- actor: claude-code
  id: 01m1rzp70cbzkj80azkna2mqe4
  text: |-
    ### commit — changed
    - evidence: bcad4cf feat(router): add the samplingMode seam on Router and every makeSession signature (local only, branch `pool`, tree clean)
    - next: `/review 01M1RRG1E1EVTDZVRQ919T04M2 HEAD~1..HEAD`
  timestamp: 2026-09-05T14:31:17.260412+00:00
- actor: claude-code
  id: 01m1rzzt26ya12v7fhfp1452s6
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` → 0 findings, 0 confirmed, 0 refuted; 14 files reviewed (the 2 `.kanban/` records are excluded by `.reviewignore`). No prior `## Review Findings` section on the card.
    - next: move the card to `done`.
  timestamp: 2026-09-05T14:36:31.686120+00:00
- actor: claude-code
  id: 01m1s00bfydmzahphmng4zat2a
  text: |-
    ### finish iteration 1 — review clean, card moved to done
    - implement: changed — Sources/FoundationModelsRouter/Resolution/ModelLoader.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/ResidencyStubs.swift, Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterTests/CompactionTracingTests.swift
    - test: green — `swift test` → 1230 tests in 133 suites passed and 83 tests in 10 suites passed; 0 failures, 0 skipped, 0 source warnings
    - commit: bcad4cf
    - review: clean — `review sha HEAD~1..HEAD`, 0 findings
  timestamp: 2026-09-05T14:36:49.534597+00:00
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
position_column: done
position_ordinal: ffffc880
title: 'Sampling mode, step A: add the samplingMode seam on Router and every makeSession signature'
---
Plan: `model-pool.md` §2.2, §2.5 step A.

## What
With a process-wide pool, two routers over one key share one container. `MLXFoundationModelsContainer.samplingMode` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`) would give the second router the first router's decoding strategy. The sampling mode is a decode option, not a property of the weights. This step adds the seam; the removal of the stored property is step B.

- `Router.init` gains `samplingMode: GenerationOptions.SamplingMode? = nil`. `RoutedModel` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift`) carries it.
- All four `LoadedLLMContainer.makeSession` signatures in `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift` gain a `samplingMode:` parameter: `makeSession(instructions:samplingMode:)`, `makeSession(instructions:tools:samplingMode:)`, `makeSession(transcript:samplingMode:)`, `makeSession(transcript:tools:samplingMode:)`. Default extensions forward to the old signatures, so stub containers compile unchanged.
- `MLXFoundationModelsContainer` implements the new signatures and passes the parameter to `MLXFoundationModelsSessionBackend`. When the parameter is `nil` it falls back to its stored property, so step B can remove the property with no behaviour change in between.
- Every call the router makes on a container passes the router's mode. Search `Sources/` for `container.makeSession(`. The one site that has no other route to the mode is the compaction summarizer in `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift` line 145: `profile.flash.container.makeSession(instructions: nil)`. A fork (`makeFork(tools:)`) and a transcript replace (`replacingTranscript(_:)`) copy the mode from the backend they start from and need no change.

## Acceptance Criteria
- [x] `Router(samplingMode: .greedy)` reaches the backend behind a root session, a session seeded from a transcript, and the compaction summarizer.
- [x] Two routers with different modes over one pool each see their own mode.
- [x] Every existing stub `LoadedLLMContainer` in `Tests/` compiles unchanged.
- [x] `swift test` → green.

## Tests
- [x] New test in `Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift`: a stub container records the mode each `makeSession` receives; router A with `.greedy` and router B with `nil` over one pool record `.greedy` and `nil` respectively.
- [x] New test in `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift`: the summarizer backend built for `compact()` with the `flash` override receives the router's mode.
- [x] Run `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router-api