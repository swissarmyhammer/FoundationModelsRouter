---
assignees:
- claude-code
depends_on:
- 01M746AMZS89CKDJN8CGMQ628D
position_column: todo
position_ordinal: '8680'
title: 'R4: joint fit gives the decision slot only the memory left after embedding, standard and flash'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R4, and decision D8.

Files: `Sources/FoundationModelsRouter/Resolution/JointFit.swift`, `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`.

- The decision slot is a pass AFTER the trio (embedding, standard, flash) wins, at the context that the trio chose. It is NOT part of `attemptTrio`, `searchWindow` or `largestConfirmedWindow`. Thus the decision slot can never make the joint fit select a smaller standard or flash model, or a smaller window.
- The pass uses the budget that is left after the trio charges.
- A candidate that is the same model as an allocated model (standard, flash or embedding winner, and the same pool key) costs 0 more bytes.
- Candidates are tried in preference order; the first that fits wins (`Verdict.chosen`); later ones are `skippedHigherPreferenceChosen`.
- If no candidate fits, the slot uses the flash winner. The resolution records each rejected candidate with its reason (`tooLarge`, `metadataUnavailable(...)`) and "fallback: flash model". The decision slot never blocks a profile, also with an empty `decision` list.
- Replace the always-fallback code of the R2/R6 task with this pass.

## Acceptance Criteria
- [ ] With room, the first decision candidate that fits is chosen.
- [ ] With no room, the slot is the flash winner, and each candidate has its rejection reason.
- [ ] A decision candidate equal to the standard or flash winner is chosen with 0 charged bytes.
- [ ] For a profile where a large decision candidate would leave no room for the preferred standard model, the standard and flash winners and the window are the same as for the same profile with `decision: []`.
- [ ] An empty decision list gives the flash fallback.

## Tests
- [ ] Add cases to `Tests/FoundationModelsRouterTests/JointFitTests.swift` for each criterion above (fixed context and derived window).
- [ ] Add one end-to-end case to `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: a decider candidate that fits is the chosen ref of `profile.decision`.
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- The 0-byte rule is the same rule as in R2/R6 and R8: the same pool key as a model that this resolve allocated costs 0 bytes in the fit, in the hold and in the handle `footprintBytes`.
- Put the new end-to-end case in `Tests/FoundationModelsRouterTests/DecisionSlotFitTests.swift` (not in `DecisionSlotResolveTests.swift`), so that the tasks do not edit the same file.
