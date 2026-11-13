---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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
- [ ] The sizing step records `decision.type` of a GGUF model, and records none for an MLX model.
- [ ] A GGUF model with a supported `decision.type` resolves to the native path (`PooledNativeDecisionModel`).
- [ ] A model with no supported `decision.type` and a `decider_config.json` resolves to `DeciderPromptFormat`.
- [ ] Any other model resolves to `GenericPromptFormat`.

## Tests
- [ ] Unit tests over stub metadata for each of the three branches, and for an MLX model, in `Tests/FoundationModelsRouterTests/` (next to the existing decision slot plan tests).
- [ ] A unit test that reads `decision.type` from a stub GGUF header.
- [ ] `swift test` passes, with the test count checked (a `--filter` that matches nothing exits 0).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision