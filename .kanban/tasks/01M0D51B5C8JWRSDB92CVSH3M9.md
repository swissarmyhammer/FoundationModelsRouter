---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dtbawgb57x7554s37v3z8c
  text: |-
    Implementation record.

    What changed:
    - New plain target `FoundationModelsRouterRealModelSupport` (Tests/FoundationModelsRouterRealModelSupport). It holds `RealModelHarness`, `RealModelContainer`, `RealModels`, `CompactionFold`, the new `CompactionRoundTripFixture` (the scripted turns, context, reply ceiling, instructions, fold budget), the new `CompactionRecordingFixture` accessor, and the `Fixtures/CompactionRecording` resource. The unit target and the integration target depend on it.
    - Router declarations became `package`, each with a stated reason in its doc comment: `RoutedModel.init`, `LanguageModelProfile.init`, `ResidentModelGates` (type and init), `MLXFoundationModelsContainer` (type, `languageModel`, and four `makeSession` witnesses), and `Compactor.estimatedTokenCount(of: String)`. No `public` declaration changed.
    - Three hermetic suites moved to the unit target: `RealModelHarnessTests` (5 tests), `ScriptedTurnSizingTests` (4 tests, new file, reads `CompactionRoundTripFixture`), and `RecordedFixtureRedactionTests` (1 test). The card names nine tests; the redaction test was added after the card and is also hermetic, so it moved too. After the move, `--filter IntegrationTests` selects only real-model suites.
    - `RealModelHarnessTests` now uses the unit target's `UndrivenLanguageModelContainer`. Its private stub types are deleted, because the unit target already has an internal `StubSessionBackend` and the two names collided.
    - The gated `CompactionRoundTripIntegrationTests` and `RecordedTranscriptCompactionIntegrationTests` read the fixture values through the support target. Eleven other integration files got the new import.
    - `Tools/RecordCompactionFixture` prose and the eval runner's "Why this is not RealModelHarness.make" doc section now point at the new location. Follow-up card ^bh97dp7 folds the eval runner onto the harness.

    What did not work at first:
    - `public` members of the support target cannot expose the `package` type `MLXFoundationModelsContainer`. `RealModelContainer.load`, `CompactionFold.run`, and `CountingBlankSlateSummarizer.init` are `package` for that reason.
    - A public struct gets no implicit `Sendable`. `CountingBlankSlateSummarizer.Call` and `CompactionFoldOutcome` declare it.
    - The `edit file` op with `replace_all` replaced 1 of 4 identical sites and reported success. Each site got its own edit, and a grep verified zero remained.

    Discoveries:
    - A witness of a public protocol on a `package` type must be at least `package`. The five `MLXFoundationModelsContainer` witnesses are widened for that rule, not for a direct caller.
    - `import Testing` and `#require` compile in a plain target under `swift build -c release` (the release log shows the target compiled).
  timestamp: 2026-08-19T20:10:37.328099+00:00
- actor: claude-code
  id: 01m0dtbsa1ybz8t2c84mrg3605
  text: |-
    ### implement — changed
    - evidence: 27 files — Package.swift; Sources/FoundationModelsRouter/{LanguageModelProfile.swift, Concurrency/ResidentModelGates.swift, Resolution/LiveModelLoader.swift, Compaction/Compactor.swift}; Tests/FoundationModelsRouterRealModelSupport/* (new target: RealModelHarness, RealModelContainer, RealModels, CompactionFold, CompactionRoundTripFixture, CompactionRecordingFixture, Fixtures moved); Tests/FoundationModelsRouterTests/{RealModelHarnessTests.swift, ScriptedTurnSizingTests.swift, RecordedFixtureRedactionTests.swift}; 13 integration files; the eval runner doc; Tools/RecordCompactionFixture prose. Verification: `swift test list` puts the 10 moved tests under FoundationModelsRouterTests (1018 unit + 75 eval hermetic; 29 + 3 IntegrationTests, all real-model); `Scripts/swift-test.sh --skip IntegrationTests` passed — 1018 tests in 96 suites (1 pre-existing known issue in BoundedWait) and 75 tests in 8 suites, the three moved suites green; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift build -c release` clean in 85.9 s and it compiled the new target.
    - next: /review. Follow-up card ^bh97dp7 folds the eval runner onto RealModelHarness.
  timestamp: 2026-08-19T20:10:52.097906+00:00
- actor: claude-code
  id: 01m0dtj2jjqzvfp8wmb5nc72js
  text: |-
    ### test — green
    - command: Scripts/swift-test.sh --skip IntegrationTests
    - result: 1018 tests in 96 suites passed, plus 75 tests in 8 suites passed. 1 known issue (BoundedWaitTests, pre-existing, counts as green).
    - command: swift build --build-tests -Xswiftc -warnings-as-errors
    - result: Build complete. No new warnings. One old note stays: a SwiftPM resource message about the vendored mlx-swift bundle. This note is not a Swift code warning.
    - check: swift test list 2>/dev/null | grep -c IntegrationTests → 32. All 32 items are real-model tests under the IntegrationTests target. No unit test sits in the wrong target.
    - next: none. The build is clean.
  timestamp: 2026-08-19T20:14:18.194741+00:00
position_column: doing
position_ordinal: '8480'
title: Nine hermetic tests of the real-model target run only under the real-model selector
---
Found while landing ^ryb01x7, which moved the real-model suites behind a target selector.

`Tests/FoundationModelsRouterIntegrationTests` holds two suites that need no model at all:

- `RealModelHarnessTests` — 5 tests, builds a whole `LanguageModelProfile` over a stub container and reads back every fact `RealModelHarness.make(...)` stamps.
- `ScriptedTurnSizingTests` — 4 tests, holds `CompactionRoundTripIntegrationTests.scriptedTurns` to the token band the live run needs.

Both run in milliseconds. Both are now left out by the everyday `swift test --skip IntegrationTests`, and reach a runner only through the CI real-model job or through an explicit
`swift test --filter 'FoundationModelsRouterIntegrationTests\.(RealModelHarnessTests|ScriptedTurnSizingTests)'`.

## Why they could not move, measured

Two SwiftPM facts, both measured on Apple Swift 6.4 with the default `swiftbuild` build system:

1. A `.testTarget` that another target depends on IS compiled by `swift build -c release`, and its `@testable import` then fails with `unable to resolve Swift module dependency to a compatible module`. The same package with the dependency removed builds clean in release.
2. Two targets cannot share a source file: `target 'X' has overlapping sources`.

Together they mean `@testable` code lives in exactly one leaf test target. `RealModelHarness` needs `@testable` because `LanguageModelProfile`'s initializer is internal, and so are `RoutedLLM`'s, `RoutedEmbedder`'s, `SlotResolution`'s, `DurableRecording`'s and `SessionSidecarWriter`'s. So the harness cannot move to a plain package target, and its hermetic proof cannot leave the harness.

## The shape that would close it

Widen the initializers `RealModelHarness` calls from `internal` to `package`, the way ^ryb01x7 widened `TranscriptTurns` and `Compactor.estimatedTokenCount(of:)` for the evals' machinery. `package` stops at this package's boundary, so the library's public surface does not move. `RealModelHarness`, `RealModelContainer`, `RealModels` and `CompactionFold` could then live in a plain `FoundationModelsRouterRealModelSupport` target, `RealModelHarnessTests` could live beside the other hermetic tests, and the scripted-turn fixture and its sizing suite could split the same way.

Count the initializers before committing to it: about a dozen, each needing a doc paragraph saying why it is `package`, and each producing a `visibility changed` row for the review engine to read.

## Acceptance Criteria

- [x] The declarations `RealModelHarness` needs are `package`, each with a stated reason
- [x] `RealModelHarness` and the scripted-turn fixture live in a plain target both the real-model target and a hermetic target can depend on
- [x] `RealModelHarnessTests` and `ScriptedTurnSizingTests` run under `swift test --skip IntegrationTests`
- [x] `swift build -c release` stays clean
- [x] The library's public surface is unchanged #test-debt