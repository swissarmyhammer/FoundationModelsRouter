---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m75gnkx1qe9y36e8yv0hwt7p
  text: |-
    Research:
    - `Router.footprintBytes` already sizes each slot of the LLM role (standard, flash, decision) as an LLM, because `ModelSlot.decision.poolRole == .llm`. It uses `ModelSlot.standard.poolKey` for each LLM slot. All LLM slots give the same key, so the GGUF figure of a decision candidate is already the flash figure. The GGUF test is a check of the current behavior.
    - The Core ML check reads only `.standard` and `.flash`. A Core ML model in the decision list only is sized as an LLM with no error. This is the gap.
    - `sizeCandidates` and `slotMembership` read `ProfileDefinition.candidatesBySlot`, which has `.decision`. So the decision candidates are fetched in the same task group as the other slots, once per `sizingKey`.
    - `JointFit` does not call `footprint` for decision candidates yet (R2/R6 marks them `.notFitted`). R4 (task 01M746AWW5JWZK2017CJMC5VMJ) adds the decision pass. So R8 gives `footprintBytes` the rule for a key that this resolve allocated: a new `allocatedKeys` parameter (default empty). A key in `allocatedKeys` that serves the request costs 0; a key in `residentKeys` costs the session KV; else the full footprint. `acquire` already charges 0 for a key in `heldKeys`.
    - Plan: size each slot of the membership with that slot's own `poolKey`, take the largest. The Core ML message names each LLM slot that lists the ref (standard, flash, decision order).
  timestamp: 2026-11-11T14:37:25.793370+00:00
- actor: claude-code
  id: 01m75gysyta9teg74txvp783wt
  text: |-
    Implementation landed.
    - `Router.footprintBytes` now sizes each slot that lists the ref under that slot's own `poolKey` (`ModelSlot.decision.poolKey` for the decision slot) through a new private `SlotPricing`, and keeps the largest figure. New parameter `allocatedKeys: Set<ModelPoolKey> = []`: a key there that `canServe` the request costs 0. A key in `residentKeys` costs the session KV (LLM) or 0 (embedder). `runJointFit` passes no `allocatedKeys`, because the trio fit allocates nothing before it sizes. R4 must pass the keys of the trio winners for the decision pass.
    - `coreMLInGenerationSlotMessage(for:)` is now `coreMLInLLMSlotMessage(for:slots:)`. The message names each LLM slot that lists the ref, in the order standard, flash, decision ("it cannot fill the flash or decision slot"). The old text "the standard or flash slot" for one slot changed to "the standard slot" / "the flash slot". The existing parameterized test changed to match.
    - RED seen: 6 issues (3 Core ML message cases, the flash+decision message, the embedding+decision rejection, the allocated-key 0-byte case). The GGUF "decision sized like flash", "resident costs session KV", "smaller allocated context is charged in full" and the two fetch-once tests passed before the change: they check behavior that already existed (the task says no GGUF sizing change is expected).
    - No change in `Sizing/GGUFRepoMetadata.swift` or `Sizing/RepoMetadata.swift`.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/RepoMetadataTests.swift, Tests/FoundationModelsRouterTests/GGUFResolveTests.swift, Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift; `swift test` once: 2612 tests in 302 suites passed (plus 41 and 19), 0 failures; only warning is the existing build-system "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: /review
  timestamp: 2026-11-11T14:42:26.906214+00:00
- actor: claude-code
  id: 01m75h5gb7fggmb90z42s9zn4b
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9d513c1e). 0 findings, 0 confirmed, 3 refuted. 4 code files reviewed. 4 .kanban files not reviewed (ignore rule).
    - next: The task is in done. No work is open.
  timestamp: 2026-11-11T14:46:06.439119+00:00
- actor: claude-code
  id: 01m75h5x4bdpxtddrz273dvv4r
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Router.swift (per-slot pool key sizing, allocatedKeys 0-byte rule, Core ML message), 3 test files
    - test: green — swift test, 2612 + 41 + 19 passed, 0 skipped
    - commit: 9d513c1e
    - review: clean — 0 findings
  timestamp: 2026-11-11T14:46:19.531846+00:00
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: done
position_ordinal: ffffffffff80
title: 'R8: size decision candidates like generation candidates; reject Core ML'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R8. In the plan, R8 comes late. It moves before R4 here, because the joint fit cannot size a decision candidate without it.

- `Router.swift`, `static func footprintBytes(for:context:metadataByRef:membership:residentKeys:)`: a ref whose membership has `.decision` is sized like a generation candidate (weights + drafter + one session KV at the context; a resident key that can serve the decision key costs only the session KV, the same rule as standard/flash). Use `ModelSlot.decision.poolKey(of:context:)`.
- The Core ML rejection: a Core ML embedding model in the decision slot gives `metadataUnavailable` with a clear message, the same as for standard and flash. Update `coreMLInGenerationSlotMessage(for:)` (or add a decision message) so that the text names the decision slot.
- Make sure the metadata fetch of the resolve covers the decision candidates (it reads `candidatesBySlot`).
- `Sizing/GGUFRepoMetadata.swift`, `Sizing/RepoMetadata.swift`: no change is expected for GGUF sizing; check it and add a test.

## Acceptance Criteria
- [x] A GGUF decision candidate gets the same footprint as the same ref in the flash slot at the same context.
- [x] A Core ML embedding model in the decision list gives `metadataUnavailable` with a message that names the decision slot.
- [x] The metadata of each decision candidate is fetched once, in the same pass as the other slots.

## Tests
- [x] Add cases to `Tests/FoundationModelsRouterTests/GGUFResolveTests.swift` (GGUF decision candidate sized like flash, with `GGUFHeaderFixtures`) and to the Core ML tests in `Tests/FoundationModelsRouterTests/ResolveTests.swift` (or the file that tests `coreMLInGenerationSlotMessage`).
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- One rule with R2/R6 and R4: a decision candidate that is the same pool key as a model that THIS resolve allocated (standard, flash or embedding winner) costs 0 bytes, not "only the session KV". A model that another router keeps resident costs the session KV, the same as for standard/flash.
