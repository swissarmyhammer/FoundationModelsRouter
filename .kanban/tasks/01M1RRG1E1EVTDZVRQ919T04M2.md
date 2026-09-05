---
assignees:
- claude-code
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
position_column: todo
position_ordinal: '8480'
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
- [ ] `Router(samplingMode: .greedy)` reaches the backend behind a root session, a session seeded from a transcript, and the compaction summarizer.
- [ ] Two routers with different modes over one pool each see their own mode.
- [ ] Every existing stub `LoadedLLMContainer` in `Tests/` compiles unchanged.
- [ ] `swift test` → green.

## Tests
- [ ] New test in `Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift`: a stub container records the mode each `makeSession` receives; router A with `.greedy` and router B with `nil` over one pool record `.greedy` and `nil` respectively.
- [ ] New test in `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift`: the summarizer backend built for `compact()` with the `flash` override receives the router's mode.
- [ ] Run `swift test` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router-api