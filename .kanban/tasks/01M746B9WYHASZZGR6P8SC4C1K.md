---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76cbfraf3w1j64mdm3b2m38
  text: |-
    Research done.
    - `SessionRecord.ResolvedProfile` has 2 call sites only: `Router.buildProfile(definition:admitted:)` and `SessionIndexFileTests.makeRecord`. `Tests/.../Helpers/SessionRecordFixtures.swift` does not construct a `ResolvedProfile`.
    - One recorded fixture holds a `profile:` block: `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/index.md`. It must get a `decision:` key, because the field is required.
    - `RoutedDecider.makeSession(state:)` builds a `DecisionSession` over the container model only. It has no recorder path. Correct as it is.
    - `Recording/`: the only `switch` on `ModelSlot` is `SessionTreeRestoration.recordedHandle(for:)`. It already throws `slotNotInProfile` for `.embedding, .decision`. No `switch` on the transcript event kinds names a decision.
    - A decision that succeeds needs a `LiveLLMContainer` over `LogitsStubLanguageModel` (Helpers/StubLogits.swift). A decider candidate that fits (as in `DecisionSlotFitTests`) gives a decision ref that differs from the flash ref, so the test can tell the two fields apart.
  timestamp: 2026-11-11T22:41:13.994990+00:00
- actor: claude-code
  id: 01m76ch5eav9bzgj3zrykbwb8n
  text: |-
    Implementation landed.
    - `SessionRecord.ResolvedProfile` has the required field `decision: ModelRef`. `Router.buildProfile` gives `resolution.decision`. No reader for old records.
    - `SessionIndexFileTests.makeRecord` and the fixture `Fixtures/PreRequestRenameRecording/.../index.md` (key `decision: org/flash-a`) are updated.
    - New file `Tests/FoundationModelsRouterTests/DecisionRecordingTests.swift`, as the board check says: (1) the root `index.md` records `profile.decision.chosen`; (2) that record round-trips through JSONEncoder/JSONDecoder; (3) a `decide` on the decision handle changes no byte of any file under the recording root, after a `respond` wrote the root transcript. The decision candidate fits, so its ref is not the flash ref. A loader gives a `LiveLLMContainer` over `LogitsStubLanguageModel` for that ref, so the decision succeeds.
    - TDD: tests 1 and 2 failed first with "value of type 'SessionRecord.ResolvedProfile' has no member 'decision'". Test 3 is a guard on behavior that was already correct (no recorder path on `RoutedDecider`), so it cannot fail before a change.
    - No code change in `Recording/` switches: `recordedHandle(for:)` already throws `slotNotInProfile` for `.decision`.
  timestamp: 2026-11-11T22:44:20.042726+00:00
- actor: claude-code
  id: 01m76ch8bxze9gz5rtdg6xdx22
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Recording/SessionRecord.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/DecisionRecordingTests.swift (new), Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift, Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/index.md. `swift test --filter DecisionRecordingTests`: 3 tests passed. `swift test` (one run): 2627 tests in 304 suites passed, plus 41 and 19 in the other test products, 0 warnings.
    - next: /review
  timestamp: 2026-11-11T22:44:23.037301+00:00
- actor: claude-code
  id: 01m76cpxvp7155t7qrqac92rc5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (50a8b6d5). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed.
    - next: None. The task is in done.
  timestamp: 2026-11-11T22:47:28.886565+00:00
- actor: claude-code
  id: 01m76cqbajjjtbm4pny6hdf9jh
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Recording/SessionRecord.swift, Router.swift, DecisionRecordingTests.swift (new), SessionIndexFileTests.swift, one recorded fixture
    - test: green — swift test, 2627 + 41 + 19 passed, 0 skipped; IntegrationTests build exit 0
    - commit: 50a8b6d5
    - review: clean — 0 findings
  timestamp: 2026-11-11T22:47:42.674001+00:00
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
- 01M746AWW5JWZK2017CJMC5VMJ
position_column: done
position_ordinal: ffffffffff8280
title: 'R9: SessionRecord records the decision model; a decision never goes in the transcript'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R9.

- `Sources/FoundationModelsRouter/Recording/SessionRecord.swift`: `ResolvedProfile` gets `let decision: ModelRef` (the chosen model of the decision slot, which can be the flash fallback). ARCHITECTURE.md says no backward compatibility: the field is required; do not add a reader for old records.
- `Router.swift` `buildProfile(definition:admitted:)`: pass `resolution.decision`.
- Update the 4 `ResolvedProfile(` call sites and the fixtures (`Tests/FoundationModelsRouterTests/Helpers/SessionRecordFixtures.swift` and recorded JSON fixtures that hold a `resolvedProfile`, if any).
- A decision writes nothing to any transcript or session record: `RoutedDecider` has no recorder path. Check each `switch` on the transcript event kinds and on `ModelSlot` in `Recording/`; a `.decision` slot in a recorded session is not valid (restoration throws `slotNotInProfile`).

## Acceptance Criteria
- [x] A root session record of a resolved profile has `resolvedProfile.decision` equal to `profile.decision.chosen`, and it round-trips through JSON.
- [x] After `profile.decision.makeSession(state:).decide(...)` on a stub decider, the transcript files and session records on disk are byte-for-byte the same as before the call.

## Tests
- [x] Add a case to `Tests/FoundationModelsRouterTests/PerSessionRecordingRootTests.swift` (or the test that reads `resolvedProfile`) for the decision field.
- [x] New test in `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: a decision call adds no transcript event and changes no file in the session directory (the same check as the embed "no transcript" test).
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- This task now depends on R4 too, because both edit `Router.swift`.
- Put the new tests in `Tests/FoundationModelsRouterTests/DecisionRecordingTests.swift`, not in `DecisionSlotResolveTests.swift`.
