---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79h3dyj5226pykwhfx6b1y6
  text: |-
    Implementation landed (not committed).

    What changed:
    - Sizing: `GGUFModelHeader` (Sizing/GGUFRepoMetadata.swift) parses the header and reads the `STRING` value of `<arch>.decision.type` with the new `GGUFMetadataScan.stringValue(of:in:)`. `GGUFHeaderPrefix.read` returns it. `RepoMetadata.ggufDecisionType` records the text unchanged (nil for MLX and Core ML). `RepoMetadata.hasNativeDecisionType` asks only FoundationModelsLlamaCpp: `LlamaDecisionType(rawValue:)?.isSupportedByDecide`. The router keeps no list of types.
    - Selection: new `DecisionPath` enum (`.native`, `.promptFormat(format)`) in Resolution/DecisionPath.swift. `DecisionSlotPlan.path` replaces `format`. Order: supported type -> native; else decider_config.json -> DeciderPromptFormat; else GenericPromptFormat.
    - Flash fallback (my decision, documented in DecisionSlotPlan and docs/decision.md): it reads no file. It takes the native path when the flash model has a supported decision type, else GenericPromptFormat. The decision type comes from the sizing step, so it costs no read and cannot fail, and the path of a model is the same in the fallback as in the slot.
    - Container: `PooledDecisionContainer.init(hold:path:)` replaces `init(hold:format:)`. `.native` gives `PooledNativeDecisionModel(hold:)`. `Router.decisionContainer(hold:path:)` keeps the `UnavailableDecisionContainer` fallback.
    - `LiveLLMContainer` conforms to `PooledDecisions` (Resolution/LiveLLMContainerDecisions.swift), and forwards through `model as? any PooledDecisions`, as the PooledLogits forward does. A model that does not conform: `decisionType()` gives nil, `decide` throws `notDecisionCapable(ref)`. No checks before the call; errors pass unchanged.
    - Docs: docs/decision.md (new "The decision path" section, error section), README link text, DocC overview, Router.swift doc comments, DecisionFormatLoader doc.

    Notes for the next agent:
    - A RepoMetadata cache entry of a commit-pinned GGUF ref written before this change decodes with `ggufDecisionType == nil`, so such a ref stays on a prompt format until its cache file is removed. No migration code, by the ARCHITECTURE.md rule.
    - `LlamaDecisionType` raw value of the image type is `openbmb-minicpm-ocr-jev` (plan.md says `minicpm-ocr-jev`).
    - No Package.swift change: the router target already links FoundationModelsDecisionPooled and FoundationModelsLlamaCpp.
  timestamp: 2026-11-13T04:01:56.178771+00:00
- actor: claude-code
  id: 01m79h3rx4y261rnq6w6vnx054
  text: |-
    ### implement — changed
    - evidence: `swift test` at the root: 2671 tests in 308 suites passed (was 2648; 23 new), 41 passed, 19 passed. Only the known "missing creator for mutated node ... mlx-swift_Cmlx.bundle" warning. `swift build --package-path IntegrationTests --build-tests`: Build complete, no warnings from our sources (only third-party mlx C++ warnings and the known bundle warning). RED seen first: 10 new tests failed on the skeleton, then passed.
    - files: Sources/FoundationModelsRouter/Resolution/{DecisionPath.swift (new), LiveLLMContainerDecisions.swift (new), DecisionSlotPlan.swift, PooledDecisionContainer.swift, DecisionFormatLoader.swift}, Sources/FoundationModelsRouter/Sizing/{GGUFRepoMetadata.swift, GGUFMetadataScan.swift, RepoMetadata.swift}, Sources/FoundationModelsRouter/Router.swift, DocC FoundationModelsRouter.md, docs/decision.md, README.md; tests: DecisionSlotPlanTests, PooledDecisionContainerTests, GGUFRepoMetadataTests, LocalRepoMetadataTests, RepoMetadataTests, DecisionSlotFitTests, GGUFResolveTests, Helpers/GGUFHeaderFixtures.swift, Helpers/DecisionsStubLanguageModel.swift (new).
    - next: /review. Not committed; task stays in doing.
  timestamp: 2026-11-13T04:02:07.396373+00:00
- actor: claude-code
  id: 01m79hrtgxy6r6qh4ct8794eys
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — sizing reads `{arch}.decision.type` (RepoMetadata.ggufDecisionType); support is asked of FoundationModelsLlamaCpp (`LlamaDecisionType(rawValue:)`, `isSupportedByDecide`); DecisionPath (.native / .promptFormat); LiveLLMContainer forwards PooledDecisions; PooledDecisionContainer.init(hold:path:) makes PooledNativeDecisionModel. Added: RepoMetadataCache.schemaVersion = 2 in each cache file name, so an entry written before ggufDecisionType is never read (this replaces the earlier note that such an entry stays on a prompt format).
    - test: green — `swift test` 2672 + 41 + 19 passed, 0 warnings; `swift build --package-path IntegrationTests --build-tests` exit 0, 0 warnings.
    - commit: 554039bb
    - review: findings — Tests/FoundationModelsRouterTests/DecisionSlotPlanTests.swift:163 (plainMLXMetadata repeats deciderMetadata), Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:334 (integerDecisionTypeBytes repeats decisionBytes), Tests/FoundationModelsRouterTests/LocalRepoMetadataTests.swift:258 (decisionType constant repeated in three suites).

    ### finish iteration 2 — clean
    - implement: changed — one `mlxMetadata(hasDeciderConfiguration:)` builder; one private `decisionBytes(typedValue:keyArchitecture:)` header builder; one `GGUFHeaderFixtures.supportedDecisionType` constant used by all suites.
    - test: green — `swift test` 2672 + 41 + 19 passed, 0 warnings.
    - commit: 769b5997
    - review: clean — review sha HEAD~1..HEAD, 0 findings.
    - pins: Decision 6af3697, Extras e25cc7d, LlamaCpp c872a6b.
  timestamp: 2026-11-13T04:13:37.181717+00:00
position_column: done
position_ordinal: ffffffffff8c80
title: 'R12: Select the decision path of a GGUF model from its decision.type metadata'
---
## What
Source: ../FoundationModelsDecision/plan.md section 14 (R12). The user approved the plan.

WAIT: do not start this task until the FoundationModelsDecision session sends the shas of N3 (`PooledNativeDecisionModel`) and Extras E7 (`LlamaLanguageModel` conforms to `PooledDecisions`), and the pins are updated with `swift package --manifest-cache local update`.

Goal: a user adds a decision model with only a GGUF path. llama.cpp b12229 makes the prompt and reads the answer for each decision type in the GGUF metadata.

- In the sizing step, read `{arch}.decision.type` from the GGUF header: `Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift` (`GGUFRepoMetadata.read(name:fetch:)`) and `Sizing/GGUFMetadataScan.swift`. Record it on `RepoMetadata` (`Sizing/RepoMetadata.swift`), next to `deciderConfigurationByteCount`.
- In `Sources/FoundationModelsRouter/Resolution/DecisionSlotPlan.swift` (`DecisionSlotPlan.make`), select the path in this order:
  1. The GGUF has a supported `decision.type`: the native path, `PooledNativeDecisionModel`.
  2. Else the repository has `decider_config.json`: `DeciderPromptFormat`.
  3. Else: `GenericPromptFormat`.
- MLX models use only 2 and 3.
- Make the decision container in `Router.decisionContainer(hold:format:)` (`Router.swift`) and `Resolution/PooledDecisionContainer.swift` for the native path.

## Acceptance Criteria
- [x] The sizing step records `decision.type` of a GGUF model, and records none for an MLX model.
- [x] A GGUF model with a supported `decision.type` resolves to the native path (`PooledNativeDecisionModel`).
- [x] A model with no supported `decision.type` and a `decider_config.json` resolves to `DeciderPromptFormat`.
- [x] Any other model resolves to `GenericPromptFormat`.

## Tests
- [x] Unit tests over stub metadata for each of the three branches, and for an MLX model, in `Tests/FoundationModelsRouterTests/` (next to the existing decision slot plan tests).
- [x] A unit test that reads `decision.type` from a stub GGUF header.
- [x] `swift test` passes, with the test count checked (a `--filter` that matches nothing exits 0).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision