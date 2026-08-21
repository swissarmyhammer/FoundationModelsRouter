---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0hgeycwre2phzg27d9j1t16
  text: |-
    Research done. Both differences the survey records on `RealToolTurnComparisonTests` are still true in the code:

    1. `UnusedEmbeddingContainer.embed(texts:)` in that suite calls `Issue.record("the embedding slot is never driven by this suite")` and then answers `[]`. The harness stub answers `[]` and says nothing.
    2. `makeSession(over:)` builds `MLXFoundationModelsContainer(model: container.model, samplingMode: .greedy)` from the container it was given. `RealModelContainer.load(ref:context:samplingMode:)` takes `samplingMode` and puts it on the container at load time, and `CompactionRoundTripIntegrationTests`, `CancelledGenerationTeardownIntegrationTests` and both eval runners already load that way. So the re-wrap goes, and the two `RealModelContainer.load` calls in `respondRun()` and `streamRun()` state `samplingMode: .greedy` instead.

    Decision on the tripwire (criterion 2): the tripwire MOVES ONTO the harness stub, so no coverage is lost and every harness caller gains it. `RealModelHarness`'s own doc states that no suite which builds a profile there embeds anything, so a call that reaches the stub is always a mistake, whichever suite makes it. `RealModelHarnessTests` drives no embedding, so the ungated suite stays green. The target already links `Testing` (`RealModelContainer` uses `#require`).

    Other facts the move needs:
    - `RoutedModel.recorder`, `.routerId`, `.durableRecording` are `public`; `.generationGate` and `.forkAdmissionGate` are `internal`, and all four suites already carry `@testable import FoundationModelsRouter`.
    - Each of the four states no `contextTokens`, so each passes `context: ProfileDefinition.defaultContext`, the spelling `SessionTreeRestorationIntegrationTests` uses and `RealModelHarnessTests.statingTheProfileDefaultMatchesOmittingIt` holds to the omitted default.
    - `RecordingHandleIntegrationTests` reads `harness.router.id`; the harness returns the profile alone, so that becomes `profile.standard.routerId`, as the two suites that already moved do.
  timestamp: 2026-08-21T06:34:47.580974+00:00
- actor: claude-code
  id: 01m0hh97bcdzv9hjj0whj3gjeg
  text: |-
    ### implement — changed

    - evidence: 6 files.
      - `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift` — `UnusedEmbeddingContainer.embed(texts:)` records an issue before it answers with no vectors; `import Testing` added (the target already links it for `RealModelContainer`).
      - `Tests/FoundationModelsRouterTests/RealModelHarnessTests.swift` — new ungated test `embeddingSlotRecordsAnIssueWhenDriven`. Written first; it failed with `Known issue was not recorded` before the tripwire landed, then passed.
      - `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift` — `makeHarness()` calls `RealModelHarness.make`; `Harness` drops its `router` field and the test reads `profile.standard.routerId`.
      - `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/TranscriptReconstructionIntegrationTests.swift` — `makeHarness()` calls `RealModelHarness.make` and builds its `RoutedSessionActor` over `profile.standard`.
      - `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` — `makeChokepointHarness()` calls `RealModelHarness.make`. The router now gets the recordings directory it did not get before; no assertion reads that field.
      - `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift` — `makeSession(over:)` calls `RealModelHarness.make`, the greedy re-wrap goes, and `respondRun()`/`streamRun()` load with `samplingMode: Self.samplingMode` (a new `.greedy` constant).
    - tripwire decision: KEPT, and moved onto the harness stub. No coverage is lost, and the three other suites gain it. The harness stamps one generation model into all three slots, so a call that reaches the `.embedding` stub is always a mistake, whichever suite makes it.
    - verification: root `swift test` — 1026 tests in 96 suites passed with 2 known issues, plus 77 tests in 9 suites passed. The count is 1026 rather than 1025 because of the new tripwire test, and the second known issue is that test's own `withKnownIssue`. `swift build --build-tests -Xswiftc -warnings-as-errors` clean in the root package and in `IntegrationTests`.
    - gated run: all four suites in one process. Wall clocks are in the description. The 2 red issues are only the `cachedTokenCount` pair of `secondTurnReusesFirstTurnsKVCache` (card ^de1yq0p, fork card ^7fy0d2z); apart from them the 15 tests passed. No test came near its limit; the dearest is 84.5 s of 120 s.
    - next: /review.
  timestamp: 2026-08-21T06:49:08.716977+00:00
position_column: doing
position_ordinal: '8180'
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

## What the move did

Both differences the survey records on `RealToolTurnComparisonTests` were read again in the code, and both were still true.

The tripwire MOVED ONTO the harness stub, so no coverage is lost and every harness caller gains it. `RealModelHarness.UnusedEmbeddingContainer.embed(texts:)` now records an issue before it answers with no vectors. The harness loads one generation model and stamps it into all three slots, so a call that reaches that stub is always a mistake, whichever suite makes it. The new ungated test `RealModelHarnessTests.embeddingSlotRecordsAnIssueWhenDriven` holds the tripwire; it was written first and failed with `Known issue was not recorded` before the tripwire landed.

The greedy re-wrap went. `respondRun()` and `streamRun()` now ask `RealModelContainer.load(ref:samplingMode:)` for a greedy container at load time, and the suite states its own `samplingMode` constant, the way `CompactionRoundTripIntegrationTests` does.

No hand-built `LanguageModelProfile`, no `RoutedEmbedder(...)` call and no local `UnusedEmbeddingContainer` is left anywhere in the `IntegrationTests` package.

## The gated run

One run of 2026-08-21, all four suites in one process, `swift test --package-path IntegrationTests` with a filter for each suite. Every test is far inside `integrationTestBudgetMinutes`; the dearest is 84.5 seconds of a 120 second budget.

| suite | suite wall clock | dearest test |
|---|---|---|
| `TranscriptReconstructionIntegrationTests` | 16.8 s | 16.8 s |
| `RecordingHandleIntegrationTests` | 18.3 s | 18.3 s |
| `RealToolTurnComparisonTests` | 125.3 s | 84.5 s |
| `LanguageModelSessionBackendIntegrationTests` | 281.5 s | 47.2 s |

The run reports 2 issues, and both are the two red expectations on `cachedTokenCount` in `secondTurnReusesFirstTurnsKVCache`. That is card `^de1yq0p`, whose cause is proved to be in the vendored fork (fork card `^7fy0d2z`). Those two must stay red. Apart from them, every one of the 15 tests passed.

## Acceptance Criteria

- [x] The four suites call `RealModelHarness.make`, and no hand-built `LanguageModelProfile` is left in the integration target
- [x] `RealToolTurnComparisonTests` keeps its embedding tripwire, or the card records why the tripwire goes
- [x] Each of the four suites is run once and is green, and the wall clock is recorded on this card
- [x] Root `swift test` is green and both packages build clean with `-warnings-as-errors` #compaction #real-model #tests