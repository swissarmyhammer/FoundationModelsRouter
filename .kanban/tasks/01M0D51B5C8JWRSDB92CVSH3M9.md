---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: Nine hermetic tests of the real-model target run only under the real-model selector
---
Found while landing ^ryb01x7, which moved the real-model suites behind a target selector.

`Tests/FoundationModelsRouterRealModelTests` holds two suites that need no model at all:

- `RealModelHarnessTests` — 5 tests, builds a whole `LanguageModelProfile` over a stub container and reads back every fact `RealModelHarness.make(...)` stamps.
- `ScriptedTurnSizingTests` — 4 tests, holds `CompactionRoundTripIntegrationTests.scriptedTurns` to the token band the live run needs.

Both run in milliseconds. Both are now left out by the everyday `swift test --skip FoundationModelsRouterRealModel`, and reach a runner only through the CI real-model job or through an explicit
`swift test --filter 'FoundationModelsRouterRealModelTests\.(RealModelHarnessTests|ScriptedTurnSizingTests)'`.

## Why they could not move, measured

Two SwiftPM facts, both measured on Apple Swift 6.4 with the default `swiftbuild` build system:

1. A `.testTarget` that another target depends on IS compiled by `swift build -c release`, and its `@testable import` then fails with `unable to resolve Swift module dependency to a compatible module`. The same package with the dependency removed builds clean in release.
2. Two targets cannot share a source file: `target 'X' has overlapping sources`.

Together they mean `@testable` code lives in exactly one leaf test target. `RealModelHarness` needs `@testable` because `LanguageModelProfile`'s initializer is internal, and so are `RoutedLLM`'s, `RoutedEmbedder`'s, `SlotResolution`'s, `DurableRecording`'s and `SessionSidecarWriter`'s. So the harness cannot move to a plain package target, and its hermetic proof cannot leave the harness.

## The shape that would close it

Widen the initializers `RealModelHarness` calls from `internal` to `package`, the way ^ryb01x7 widened `TranscriptTurns` and `Compactor.estimatedTokenCount(of:)` for the evals' machinery. `package` stops at this package's boundary, so the library's public surface does not move. `RealModelHarness`, `RealModelContainer`, `RealModels` and `CompactionFold` could then live in a plain `FoundationModelsRouterRealModelSupport` target, `RealModelHarnessTests` could live beside the other hermetic tests, and the scripted-turn fixture and its sizing suite could split the same way.

Count the initializers before committing to it: about a dozen, each needing a doc paragraph saying why it is `package`, and each producing a `visibility changed` row for the review engine to read.

## Acceptance Criteria

- [ ] The declarations `RealModelHarness` needs are `package`, each with a stated reason
- [ ] `RealModelHarness` and the scripted-turn fixture live in a plain target both the real-model target and a hermetic target can depend on
- [ ] `RealModelHarnessTests` and `ScriptedTurnSizingTests` run under `swift test --skip FoundationModelsRouterRealModel`
- [ ] `swift build -c release` stays clean
- [ ] The library's public surface is unchanged

#test-debt