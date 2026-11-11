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
- actor: claude-code
  id: 01m76bs7e624e1spt3c24378p9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (33bb9646). 2 findings (2 confirmed, 6 refuted). Tests/FoundationModelsRouterTests/JointFitTests.swift:1104, Tests/FoundationModelsRouterTests/JointFitTests.swift:1126
    - next: Parameterize the two pairs of duplicate free-candidate tests in JointFitTests.swift. Then run the review again.
  timestamp: 2026-11-11T22:31:15.654574+00:00
- actor: claude-code
  id: 01m76bsr1hp4ztg9g04h3ez2v8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — JointFit.swift (decision pass after the trio), SlotResolution.swift, Router.swift, LanguageModelProfile.swift, 6 test files (1 new)
    - test: green — swift test, 2631 + 41 + 19 passed, 0 skipped; IntegrationTests build exit 0
    - commit: 33bb9646
    - review: findings — Tests/FoundationModelsRouterTests/JointFitTests.swift:1104, Tests/FoundationModelsRouterTests/JointFitTests.swift:1126
  timestamp: 2026-11-11T22:31:32.657171+00:00
- actor: claude-code
  id: 01m76c197sb9f90r3751v5fktk
  text: |-
    Review findings fixed (2 duplication findings in JointFitTests.swift).
    - The cause was the same in all the new decision tests: each criterion had a fixed-context test and a derived-window copy, and the free-candidate check had a standard copy and a flash copy. Only a value changed.
    - New `JointFitTests.DecisionContext` enum (`fixed`, `derived`) holds `resolveWithRoom(_:)`, `resolveWithNoRoom(_:)`, `crowdingDecider`, `resolveCrowded(_:)` and `winner(of:)`. New `JointFitTests.GenerationSlot` enum (`standard`, `flash`) makes the switch in `winner(of:)` exhaustive, with no catch-all case (state-modeling rule).
    - Parameterized tests now: chooses the first candidate that fits, no room uses the flash winner, no room records each rejection reason, a candidate equal to a generation winner is free (context x slot = 4 cases, replaces 4 tests), a crowding candidate keeps the trio and the window, an empty list gives the flash winner, an empty list records the flash fallback. The old empty-list test had two `#expect`; it is now two tests with one assertion each.
    - The fixed-only tests (skipped later candidates, no fallback with room, flash fallback with no room, embedding winner is charged) stay single tests. They have no derived copy.
    - The derived crowding case keeps its earlier values (`deciderSmall` at `windowBigBudget`); the fixed case keeps `deciderLarge` at `decisionRoomBudget`.
    - DecisionSlotFitTests.swift has one test, so it has no duplicate. Tests from before 33bb9646 are not changed.
    - Test functions went from 18 to 11, so the full-suite count is 2624 (was 2631).
  timestamp: 2026-11-11T22:35:39.641142+00:00
- actor: claude-code
  id: 01m76c1bhh3e58dxbbbbxqqd0v
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsRouterTests/JointFitTests.swift. `swift test` one full run: 2624 tests in 303 suites passed, plus 41 and 19, 0 failures, 0 compiler warnings. After the last edit (the GenerationSlot enum, JointFitTests.swift only): `swift test --filter JointFitTests` ran 45 tests in 2 suites, all passed, no warnings. Both review findings are checked `- [x]`.
    - next: /review
  timestamp: 2026-11-11T22:35:42.001240+00:00
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

## Review Findings (2026-11-11 17:26)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/JointFitTests.swift:1104` `duplication/duplication` — decisionEqualToTheStandardWinnerIsFree repeats decisionEqualToTheFlashWinnerIsFree (line 1097) with only the candidate reference changed from flash3b to std32b8. Copies of one assertion drift out of sync and inflate the test surface. Replace the two tests with one parameterized test over [flash3b, std32b8] (a parameterized @Test with arguments, or a helper taking the ref and asserting the free chosen report). Keep one named test per case if the suite convention requires distinct names.
- [x] `Tests/FoundationModelsRouterTests/JointFitTests.swift:1126` `duplication/duplication` — derivedDecisionEqualToTheStandardWinnerIsFree repeats derivedDecisionEqualToTheFlashWinnerIsFree (line 1118). Only the ref in the decision list differs (windowBig instead of windowFlash). Parameterize over the two refs in one test (or one helper), so the derived-window free-candidate check is written once.
