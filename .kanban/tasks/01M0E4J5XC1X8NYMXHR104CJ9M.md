---
assignees:
- claude-code
position_column: todo
position_ordinal: '9e80'
title: MultiModelGeneration observes the routed session, not a standalone ResolutionProgress
---
The user read the MultiModelGeneration example and reports that `ResolutionProgress` is not well integrated. A standalone use of `ResolutionProgress` is useless as a sample. The example must show what a real caller does: observe a routed session.

## What

Rework `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Examples/MultiModelGeneration/main.swift` (105 lines):

- Remove the standalone `let progress = ResolutionProgress()` block at lines 52-56 as its own demonstration. Keep resolution progress only as part of one continuous observation story: resolve with `reporting:`, print each phase transition from `progress.phases`, and then keep observing the SAME story as the sessions generate.
- Drive the generation turns through session observation: use `streamEvents(to:)` (or `streamSessionEvents()`) on the `RoutedSession` so the example prints turn events — `turnStarted`, `textDelta`, and the turn end — instead of only awaiting a final string. The flash triage turn and the standard streamed turn both read as one observed session flow.
- Update `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Examples/MultiModelGeneration/README.md` to describe the observation flow.
- The example stays under 2 minutes with its current small models.

## Acceptance Criteria

- [ ] `main.swift` holds no standalone `ResolutionProgress` demonstration; progress prints as part of the resolve-then-generate flow
- [ ] At least one generation turn is driven through session event observation and prints named `SessionEvent` cases as they arrive
- [ ] One recorded run of `swift run MultiModelGeneration` completes in under 2 minutes and its wall clock is recorded on this card
- [ ] The README describes the observation flow

## Tests

- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0 (the example target compiles warning-free)
- [ ] `Scripts/swift-test.sh --skip IntegrationTests` (or the current hermetic command) passes with unchanged counts
- [ ] One run of `swift run MultiModelGeneration` exits 0; the implementer records the wall clock and the printed event names on this card

## Workflow
- Use `/tdd` where a failing test is possible; an example executable is verified by the warnings-as-errors build and a recorded run.
#examples #router