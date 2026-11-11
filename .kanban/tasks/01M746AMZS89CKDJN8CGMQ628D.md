---
assignees:
- claude-code
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: todo
position_ordinal: '8580'
title: 'R8: size decision candidates like generation candidates; reject Core ML'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R8. In the plan, R8 comes late. It moves before R4 here, because the joint fit cannot size a decision candidate without it.

- `Router.swift`, `static func footprintBytes(for:context:metadataByRef:membership:residentKeys:)`: a ref whose membership has `.decision` is sized like a generation candidate (weights + drafter + one session KV at the context; a resident key that can serve the decision key costs only the session KV, the same rule as standard/flash). Use `ModelSlot.decision.poolKey(of:context:)`.
- The Core ML rejection: a Core ML embedding model in the decision slot gives `metadataUnavailable` with a clear message, the same as for standard and flash. Update `coreMLInGenerationSlotMessage(for:)` (or add a decision message) so that the text names the decision slot.
- Make sure the metadata fetch of the resolve covers the decision candidates (it reads `candidatesBySlot`).
- `Sizing/GGUFRepoMetadata.swift`, `Sizing/RepoMetadata.swift`: no change is expected for GGUF sizing; check it and add a test.

## Acceptance Criteria
- [ ] A GGUF decision candidate gets the same footprint as the same ref in the flash slot at the same context.
- [ ] A Core ML embedding model in the decision list gives `metadataUnavailable` with a message that names the decision slot.
- [ ] The metadata of each decision candidate is fetched once, in the same pass as the other slots.

## Tests
- [ ] Add cases to `Tests/FoundationModelsRouterTests/GGUFResolveTests.swift` (GGUF decision candidate sized like flash, with `GGUFHeaderFixtures`) and to the Core ML tests in `Tests/FoundationModelsRouterTests/ResolveTests.swift` (or the file that tests `coreMLInGenerationSlotMessage`).
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- One rule with R2/R6 and R4: a decision candidate that is the same pool key as a model that THIS resolve allocated (standard, flash or embedding winner) costs 0 bytes, not "only the session KV". A model that another router keeps resident costs the session KV, the same as for standard/flash.
