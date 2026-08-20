---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ecr36hqrqf7h2j3ncgwg7d
  text: |-
    Research is complete. Discoveries:

    - `RoutedSession.streamEvents(to:)` is a convenience in RoutedSession.swift that calls `streamEvents(to:maxTokens:)` with a nil ceiling. The event order for a plain text turn is: `turnStarted`, `textDelta` fragments, `entryRecorded` for the recorded `.response` entry, and `turnEnded` with measured `TokenUsage` (tokensIn, tokensOut, contextFill).
    - A consumer must clear its accumulated text on `textReset`. The accumulated text then equals the string `respond(to:)` returns.
    - `TurnStart.turnId` is `CustomStringConvertible`. `TurnStart.promptId` is nil for a turn whose prompt comes from the caller.
    - The CompactionDemo (task ^nwe0qt1) shows the house pattern for progress observation: `async let resolvedProfile = router.resolve(profile:reporting:)` beside a `for await` loop over `progress.phases`. No stored task handle. This replaces the standalone `Task { @MainActor in ... }` block.
    - Commit 3ba63d9 added the SmolLM caution comment above the profile definition. The comment stays, because the profile and its `flash` slot do not change.
    - The doc header claims the example is the live twin of `ExamplesTests.multiModelDirectGeneration()` with the "same call pattern". After this rework the call pattern differs (event observation, not `respond`). The header text must change to keep the claim true.
    - Plan: one shared `runObservedTurn(on:label:prompt:)` helper drives both turns through `streamEvents(to:)` and prints the named `SessionEvent` cases. The switch is exhaustive with no `default:`. The cases that cannot arrive (tools, compaction, priming, stall) are grouped with a comment. A wall clock print at the end records the runtime, as CompactionDemo does.
  timestamp: 2026-08-20T01:32:09.809464+00:00
- actor: claude-code
  id: 01m0ed869am7w2jydv2acjbae9
  text: |-
    Implementation is complete. What changed:

    - `Examples/MultiModelGeneration/main.swift`: the standalone `ResolutionProgress` block is removed. The resolve now runs as an `async let` child while the top-level code prints each phase from `progress.phases`. One shared helper, `runObservedTurn(on:label:prompt:)`, drives the flash triage turn and the standard turn through `streamEvents(to:maxTokens:)`. The helper prints each named `SessionEvent` case: `turnStarted`, `textDelta`, `textReset`, `entryRecorded`, and `turnEnded`. The switch is exhaustive with no `default:`. The SmolLM caution comment from commit 3ba63d9 stays unchanged.
    - New named constant `demoReplyTokenCeiling = 160`. The first recorded run had no ceiling. SmolLM-135M then generated 8192 tokens and the run took 121.7 seconds, which is more than the 2-minute limit. The ceiling caps each turn and the doc comment records the measurement.
    - `Examples/MultiModelGeneration/README.md`: describes the observation flow (resolve phases, then per-turn `SessionEvent` cases).

    Recorded run of `swift run MultiModelGeneration` (warm model cache):
    - Exit 0. In-program wall clock: 11.1 seconds. This is under the 2-minute limit.
    - Printed event names, in order per turn: `turnStarted`, `textDelta` fragments, `entryRecorded kind=response`, `turnEnded tokensIn=... tokensOut=... contextFill=...%`. Resolve phases printed: sizing, downloading, loading, ready.
    - Flash turn: tokensIn=36 tokensOut=160 contextFill=2%. Standard turn: tokensIn=180 tokensOut=160 contextFill=4%.

    Verification:
    - `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0.
    - `Scripts/swift-test.sh --skip IntegrationTests` passes: 1023 tests in 96 suites and 77 tests in 9 suites, 0 failures. This is the baseline count.
  timestamp: 2026-08-20T01:40:57.258426+00:00
- actor: claude-code
  id: 01m0ed9ft0hqvgnrr8m0qnjwk7
  text: |-
    ### implement — changed
    - evidence: 2 files — Examples/MultiModelGeneration/main.swift, Examples/MultiModelGeneration/README.md. `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0. `Scripts/swift-test.sh --skip IntegrationTests`: 1023 + 77 tests pass, 0 failures. `swift run MultiModelGeneration`: exit 0, wall clock 11.1 seconds.
    - next: review
  timestamp: 2026-08-20T01:41:39.776846+00:00
position_column: doing
position_ordinal: '8580'
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

- [x] `main.swift` holds no standalone `ResolutionProgress` demonstration; progress prints as part of the resolve-then-generate flow
- [x] At least one generation turn is driven through session event observation and prints named `SessionEvent` cases as they arrive
- [x] One recorded run of `swift run MultiModelGeneration` completes in under 2 minutes and its wall clock is recorded on this card
- [x] The README describes the observation flow

## Tests

- [x] `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0 (the example target compiles warning-free)
- [x] `Scripts/swift-test.sh --skip IntegrationTests` (or the current hermetic command) passes with unchanged counts
- [x] One run of `swift run MultiModelGeneration` exits 0; the implementer records the wall clock and the printed event names on this card

## Workflow
- Use `/tdd` where a failing test is possible; an example executable is verified by the warnings-as-errors build and a recorded run. #examples #router