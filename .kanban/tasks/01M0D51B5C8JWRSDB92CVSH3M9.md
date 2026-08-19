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
- actor: claude-code
  id: 01m0dv62db7qw9e4mrh1ex7v4y
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 2d2be00) — 4 findings, 4 confirmed, 1 refuted. Files: Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift:114, Tests/FoundationModelsRouterRealModelSupport/CompactionRoundTripFixture.swift:73, Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift:40, Tests/FoundationModelsRouterRealModelSupport/RealModels.swift:21. Also: the tool rule 'code-hygiene/dead-code-swift' could not run — the debug build of the working tree failed in Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift (lines 51, 52, 58), and SwiftPM reports 3 unhandled fixture files in Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording.
    - next: remove the duplicate copies in the RealModelSupport target or in IntegrationTests/Support, name the magic numbers, make the build compile again, then run the review again.
  timestamp: 2026-08-19T20:25:13.387191+00:00
- actor: claude-code
  id: 01m0dvn2vk0jrg2d7z044pqsxp
  text: |-
    Correction record for the four review findings.

    What I found:
    - The last commit copied the support files. It did not move them. The old copies stayed in Tests/FoundationModelsRouterIntegrationTests. The old copies are the same code with internal visibility and `@testable import`. The compiler used the old copies in that target, because a local declaration wins against an imported one.
    - The old fixture directory stayed in the integration target too. SwiftPM reported its 3 files as unhandled. The stale RecordedFixtureRedactionTests.swift in that target broke the debug build.

    What I changed:
    - Deleted the four old support copies: Support/CompactionFold.swift, Support/RealModelHarness.swift, Support/RealModelContainer.swift, Support/RealModels.swift. This closes the CompactionFold, RealModelHarness, and RealModels findings. Every consumer now reads the FoundationModelsRouterRealModelSupport target.
    - Deleted the stale Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift and the stale Tests/FoundationModelsRouterIntegrationTests/Fixtures directory. The fixture lives in the support target. This repairs the debug build and removes the 3 unhandled files. Package.swift was already correct; no change was necessary there.
    - Deleted the stale Tests/FoundationModelsRouterIntegrationTests/RealModelHarnessTests.swift. The unit target holds the current copy. Without this deletion, a hermetic suite stays in the real-model selector.
    - Named the fold target in CompactionRoundTripFixture.swift: a private constant `foldTargetShare` now carries the 0.25 value. I read the magic-numbers-swift rule first. I swept every file of the support target. The other numeric literals sit in named `static let` declarations, which the rule accepts.
  timestamp: 2026-08-19T20:33:25.363438+00:00
- actor: claude-code
  id: 01m0dvnf4dkactny74mqvehvm9
  text: |-
    ### implement — changed
    - evidence: 10 files. Deleted 9: Tests/FoundationModelsRouterIntegrationTests/Support/{CompactionFold,RealModelHarness,RealModelContainer,RealModels}.swift, Tests/FoundationModelsRouterIntegrationTests/{RecordedFixtureRedactionTests,RealModelHarnessTests}.swift, Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording (3 files). Edited 1: Tests/FoundationModelsRouterRealModelSupport/CompactionRoundTripFixture.swift (named constant `foldTargetShare` replaces the 0.25 literal). Verification: `swift build --build-tests -Xswiftc -warnings-as-errors` — build complete, zero warnings, zero unhandled files; `Scripts/swift-test.sh --skip IntegrationTests` — 1018 tests in 96 suites passed (1 known issue in BoundedWait, pre-existing) plus 75 tests in 8 suites passed, exit 0; `swift test list` — 1125 tests total, 32 under the IntegrationTests targets, all real-model, and the 10 moved hermetic tests under FoundationModelsRouterTests, none in the wrong target. All 4 review findings are checked.
    - next: /review.
  timestamp: 2026-08-19T20:33:37.933633+00:00
- actor: claude-code
  id: 01m0dvrdpza5kz5zzx3rmkf3sz
  text: |-
    ### test — green
    - Command 1: `swift build --build-tests -Xswiftc -warnings-as-errors`. Result: build OK. No warnings. No errors.
    - Command 2: `Scripts/swift-test.sh --skip IntegrationTests`. Result: two test runs, both pass.
      - Run 1: 1018 tests in 96 suites. All pass. 1 known issue. This is the known issue in BoundedWaitTests. This counts as green.
      - Run 2: 75 tests in 8 suites. All pass.
    - No test failed. No test was skipped. No FM_ROUTER_* env vars were used.
    - next: none. The suite is clean.
  timestamp: 2026-08-19T20:35:14.783391+00:00
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
- [x] The library's public surface is unchanged

## Review Findings (2026-08-19 15:17)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 29 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> ⚠️ tool rule 'code-hygiene/dead-code-swift' failed — the tool judged nothing, so its findings are missing:
> warning: 'foundationmodelsrouter': found 3 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
>     Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording/01M0BGQR2DV5T0P9XQ1PS05K8V/session.json
>     Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording/01M0BGQR2DV5T0P9XQ1PS05K8V/transcript.jsonl
>     Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording/README.md
> The debug build of the working tree failed before the tool could judge:
> `Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift:51` — error: 'module' is inaccessible due to 'internal' protection level (`Bundle.module` resolves to `FoundationModelsRouterRealModelSupport.Bundle.module`, which is internal to that target)
> `Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift:52` — error: type 'RecordedTranscriptCompactionIntegrationTests' has no member 'recordingResourcePath'
> `Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift:58` — error: generic parameter 'some StringProtocol' could not be inferred
> `Tests/FoundationModelsRouterIntegrationTests/RecordedFixtureRedactionTests.swift:50` and `:56` — warning: no calls to throwing functions occur within 'try' expression
> error: Build failed

- [x] `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift:114` `reuse/reuse` — CompactionFold enum and its supporting types (CountingBlankSlateSummarizer, CompactionFoldOutcome) duplicate existing code from Tests/FoundationModelsRouterIntegrationTests/Support/CompactionFold.swift instead of reusing it. Both versions maintain the same logic and structure, creating a maintenance burden when either needs to be updated. Consolidate to a single location: either remove the code from IntegrationTests/Support/CompactionFold.swift and update its callers to import from RealModelSupport, or remove this new copy and have both unit and integration tests import from the existing location. Duplication creates a risk that bug fixes in one location won't propagate to the other.
- [x] `Tests/FoundationModelsRouterRealModelSupport/CompactionRoundTripFixture.swift:73` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift:40` `duplication/duplication` — The RealModelHarness enum and its supporting code (lines 40–206) are verbatim identical to Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift:40. Duplicated code must be kept synchronized on every future edit, and the duplication inflates the maintenance surface. Delete the duplicate in this new file and import `RealModelHarness` from the existing location in IntegrationTests/Support. Or, consolidate by designating this new shared target as canonical and deleting the old location (requires a separate task to update references).
- [x] `Tests/FoundationModelsRouterRealModelSupport/RealModels.swift:21` `duplication/duplication` — The RealModels enum (lines 21–48) is near-verbatim identical to Tests/FoundationModelsRouterIntegrationTests/Support/RealModels.swift:20. The two copies will drift on future maintenance. Delete the duplicate in this new file and import `RealModels` from the existing location in IntegrationTests/Support. Or consolidate by designating this new target as canonical and deleting the old location (requires a separate task). #test-debt