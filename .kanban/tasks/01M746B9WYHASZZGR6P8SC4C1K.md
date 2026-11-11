---
assignees:
- claude-code
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
- 01M746AWW5JWZK2017CJMC5VMJ
position_column: todo
position_ordinal: '8780'
title: 'R9: SessionRecord records the decision model; a decision never goes in the transcript'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R9.

- `Sources/FoundationModelsRouter/Recording/SessionRecord.swift`: `ResolvedProfile` gets `let decision: ModelRef` (the chosen model of the decision slot, which can be the flash fallback). ARCHITECTURE.md says no backward compatibility: the field is required; do not add a reader for old records.
- `Router.swift` `buildProfile(definition:admitted:)`: pass `resolution.decision`.
- Update the 4 `ResolvedProfile(` call sites and the fixtures (`Tests/FoundationModelsRouterTests/Helpers/SessionRecordFixtures.swift` and recorded JSON fixtures that hold a `resolvedProfile`, if any).
- A decision writes nothing to any transcript or session record: `RoutedDecider` has no recorder path. Check each `switch` on the transcript event kinds and on `ModelSlot` in `Recording/`; a `.decision` slot in a recorded session is not valid (restoration throws `slotNotInProfile`).

## Acceptance Criteria
- [ ] A root session record of a resolved profile has `resolvedProfile.decision` equal to `profile.decision.chosen`, and it round-trips through JSON.
- [ ] After `profile.decision.makeSession(state:).decide(...)` on a stub decider, the transcript files and session records on disk are byte-for-byte the same as before the call.

## Tests
- [ ] Add a case to `Tests/FoundationModelsRouterTests/PerSessionRecordingRootTests.swift` (or the test that reads `resolvedProfile`) for the decision field.
- [ ] New test in `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: a decision call adds no transcript event and changes no file in the session directory (the same check as the embed "no transcript" test).
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- This task now depends on R4 too, because both edit `Router.swift`.
- Put the new tests in `Tests/FoundationModelsRouterTests/DecisionRecordingTests.swift`, not in `DecisionSlotResolveTests.swift`.
