---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Move the four remaining hand-built profile copies in the integration target onto RealModelHarness
---
Task `^hxyj3q1` moved the THREE profile copies it names onto `RealModelHarness.make`. A survey done for that card found FOUR more suites in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/` that build a `LanguageModelProfile` by hand:

- `LanguageModelSessionBackendTests.swift`, `makeChokepointHarness()`
- `TranscriptReconstructionIntegrationTests.swift`, `makeHarness()`
- `RealToolTurnComparisonTests.swift`, `makeSession(over:)`
- `RecordingHandleIntegrationTests.swift`, `makeHarness()`

They were not in `^hxyj3q1`'s scope, so they stay open here.

## What the survey measured

All four are the SAME body as `RealModelHarness.make`:

- A real container from `RealModelContainer.load`.
- One `JSONLRecorder` over the recordings directory, given to the router and to every handle.
- A `DurableRecording` with the same arguments, `recordingLevel: .full` and `profile: nil`.
- ONE `ResidentModelGates` set shared by `.standard` and `.flash`, and a second set for `.embedding`.
- The same container in both generation slots.
- `SlotResolution(remainingBudgetBytes: 0, considered: [])` with no `contextTokens`, which is `ProfileDefinition.defaultContext`.

Three of the four also carry a copy of the harness's own `UnusedEmbeddingContainer`.

Each target already imports `FoundationModelsRouterRealModelSupport`, so no build change is necessary.

## What differs, per file

- `RecordingHandleIntegrationTests` — no difference. It can call `make` as it is.
- `TranscriptReconstructionIntegrationTests` — no difference. It builds a `RoutedSessionActor` by hand after the profile, but each value it needs is on the returned profile: `recorder`, `generationGate`, `forkAdmissionGate`, `durableRecording`, and `routerId`.
- `LanguageModelSessionBackendTests` — it makes its `Router` with NO `recordingsDir`, so `router.recordingsDir` is `nil` while the handles record to a real directory. `make` always gives the router that directory. Nothing in the suite reads the field, so the move corrects an inconsistency. State that in the commit message.
- `RealToolTurnComparisonTests` — two real differences. Its embedding stub calls `Issue.record` if anything embeds, which is a tripwire the harness stub does not have. And it re-wraps the container to pin greedy decoding; `RealModelContainer.load(ref:context:samplingMode:)` does that at load time, the way `CompactionRoundTripIntegrationTests` does, which removes the re-wrap.

Every one of the four names its own `definitionName` (`"test"` three times, `"real-tool-turn"` once). Nothing reads that field, and `RealModelHarness`'s own doc states why the harness keeps one name for every profile it builds.

## Acceptance Criteria

- [ ] The four suites call `RealModelHarness.make`, and no hand-built `LanguageModelProfile` is left in the integration target
- [ ] `RealToolTurnComparisonTests` keeps its embedding tripwire, or the card records why the tripwire goes
- [ ] Each of the four suites is run once and is green, and the wall clock is recorded on this card
- [ ] Root `swift test` is green and both packages build clean with `-warnings-as-errors` #compaction #real-model #tests