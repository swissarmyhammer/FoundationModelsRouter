---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76azz9g1qgfdh2mvjh1n2jd
  text: |-
    Research done.
    - `JointFit.makeResolution` is the one place that builds the decision slot (fixed context and derived window both call it). The decision pass goes there, after the trio won, at the context of the flash slot, with the budget that the flash slot left. `attemptTrio`, `searchWindow` and `largestConfirmedWindow` do not change.
    - Design: `JointFit.FootprintProvider` gets a third argument, the pool keys of the models that this resolve allocated (`Set<ModelPoolKey>`). The trio slots pass an empty set. The decision pass passes the keys of the embedding, standard and flash winners (`ModelSlot.poolKey(of:context:)`). `Router.runJointFit` gives the set to `Router.footprintBytes(allocatedKeys:)` (R8), so a candidate with the same pool key costs 0 bytes there.
    - `Verdict.notFitted` has no use after this change. Remove it.
    - `DecisionSlotResolveTests` uses one decision candidate with the same canned metadata as the trio, and a 48 GiB budget. After R4 that candidate fits, so its flash-fallback tests break. Change that suite so that the candidate cannot be sized (a metadata source that fails for the decider repo): the fallback tests then keep their meaning.
    - `DecisionSlotJointFitTests` asserts the always-fallback (`notFitted`, "sizes no decision candidate"). Those tests change to the new behavior.
    - `DecisionFormatLoader` gives `GenericPromptFormat` when the repo has no `decider_config.json`, so a decision winner that is the flash model works.
  timestamp: 2026-11-11T22:17:28.112970+00:00
- actor: claude-code
  id: 01m76bd4xacb7asr9r8v279cxs
  text: |-
    Implementation landed (TDD: the new tests failed first, for the expected reason, then passed).
    - `JointFit.FootprintProvider` is now `(ModelRef, Int, Set<ModelPoolKey>)`. The third argument is the pool keys that this resolve allocated. The trio slots pass `[]`. The new `JointFit.resolveDecision(profile:winner:footprint:)` runs from `makeResolution` (fixed context and derived window) after the trio won. It uses the context of the trio, the budget that the flash slot left, and the keys of the three winners (`allocatedKeys(of:context:)`). If no candidate is chosen, it gives `SlotResolution.flashFallback` with the verdict of each candidate.
    - `Router.runJointFit` gives the keys to `Router.footprintBytes(allocatedKeys:)`.
    - `Verdict.notFitted` and its text are removed (dead after this change).
    - Tests: 18 new cases in `JointFitTests.swift` (MARK "The decision pass"), fixed context and derived window. The new file `DecisionSlotFitTests.swift` has the end-to-end case (the board check moved it out of `DecisionSlotResolveTests.swift`).
    - Changed existing tests, because R4 replaces the always-fallback: `DecisionSlotJointFitTests` (unsizable candidates now record `metadataUnavailable`, and they are sized); `DecisionSlotPlanTests` (fixture verdict `.notFitted` -> `.tooLarge`); `DecisionSlotResolveTests` (the decider candidate now fits the 48 GiB stub budget, so the suite uses `UnsizableDeciderMetadataSource` to keep its flash-fallback tests valid; one test asserts `metadataUnavailable` in place of `notFitted`). The test closures of `JointFitTests` and `DistinctGenerationSlotsTests` take the new third argument.
    - Note: with a derived window, the window search fills the budget, so a decision candidate fits there only when the trio fits at its native window, or when it is the same model as a trio winner. This is the design of the card (the decision never makes the window smaller).
    - ARCHITECTURE.md needs no change (no new module or dependency direction).
  timestamp: 2026-11-11T22:24:39.850494+00:00
- actor: claude-code
  id: 01m76bd8c30qm6pjk89bk7xbat
  text: |-
    ### implement — changed
    - evidence: `swift test` one full run: 2631 tests in 303 suites passed, plus 41 and 19 in the other runners, 0 failures, 0 compiler warnings. Files: Sources/FoundationModelsRouter/Resolution/JointFit.swift, Sources/FoundationModelsRouter/Resolution/SlotResolution.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterTests/JointFitTests.swift, Tests/FoundationModelsRouterTests/DecisionSlotFitTests.swift (new), Tests/FoundationModelsRouterTests/DecisionSlotJointFitTests.swift, Tests/FoundationModelsRouterTests/DecisionSlotPlanTests.swift, Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift, Tests/FoundationModelsRouterTests/DistinctGenerationSlotsTests.swift
    - next: /review
  timestamp: 2026-11-11T22:24:43.395883+00:00
depends_on:
- 01M746AMZS89CKDJN8CGMQ628D
position_column: doing
position_ordinal: '80'
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
- [x] With room, the first decision candidate that fits is chosen.
- [x] With no room, the slot is the flash winner, and each candidate has its rejection reason.
- [x] A decision candidate equal to the standard or flash winner is chosen with 0 charged bytes.
- [x] For a profile where a large decision candidate would leave no room for the preferred standard model, the standard and flash winners and the window are the same as for the same profile with `decision: []`.
- [x] An empty decision list gives the flash fallback.

## Tests
- [x] Add cases to `Tests/FoundationModelsRouterTests/JointFitTests.swift` for each criterion above (fixed context and derived window).
- [x] Add one end-to-end case to `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: a decider candidate that fits is the chosen ref of `profile.decision`.
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- The 0-byte rule is the same rule as in R2/R6 and R8: the same pool key as a model that this resolve allocated costs 0 bytes in the fit, in the hold and in the handle `footprintBytes`.
- Put the new end-to-end case in `Tests/FoundationModelsRouterTests/DecisionSlotFitTests.swift` (not in `DecisionSlotResolveTests.swift`), so that the tasks do not edit the same file.
