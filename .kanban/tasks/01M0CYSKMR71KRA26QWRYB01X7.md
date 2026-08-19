---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0d37tp8e2ttvnajsdq3830v
  text: |-
    Research done. Every SwiftPM fact below was measured on the installed toolchain (Apple Swift 6.4, swiftlang-6.4.0.30.4, default `swiftbuild` build system), not remembered.

    ## What the selectors really do

    1. `--filter <regex>` and `--skip <regex>` both match `<test-target>.<test-case>`, so a bare target name selects or excludes a whole target. Measured on a probe package with targets `HermeticTests`, `AlphaRealModelTests` and `BetaRealModelEvals`: `--skip RealModel` ran the hermetic test alone; `--filter RealModel` ran both gated targets.
    2. `--filter` and `--skip` combine in one command, and each flag can be given more than one time. `--filter RealModel --skip FullDataset` ran the gated targets without the whole-dataset suite.
    3. `--list-tests` prints NOTHING when a `--filter` or a `--skip` stands beside it. It cannot show what a selector reaches. A real run is the only proof.
    4. `swift test --filter <name that matches nothing>` prints `warning: No matching test cases were run` and **exits 0**. This is the "measures nothing, reports green" failure at the selector level, so the CI command must read that warning and fail.
    5. `swift test list` DOES list a suite that `.enabled(if:)` turns off. So the card's "37 hermetic and 75 hermetic" are TOTALS, not hermetic counts. The real counts are 9 hermetic of 37 in `FoundationModelsRouterIntegrationTests` (`RealModelHarnessTests` 5, `ScriptedTurnSizingTests` 4) and 72 hermetic of 75 in `FoundationModelsRouterEvals`.

    ## What blocks a shared support target

    6. A `.testTarget` CAN depend on another `.testTarget`, and `@testable import <that target>` compiles. BUT `swift build -c release` then compiles the depended-upon test target, and its `@testable import` fails with `unable to resolve Swift module dependency to a compatible module`. Measured both ways: the same package with the dependency removed builds clean in release. So a test target that another target depends on is release-built and cannot use `@testable`.
    7. Two targets cannot share a source file: `target 'X' has overlapping sources`.
    8. A plain `.target` CAN `import Evaluations`. The framework search path is not a `.testTarget` privilege.

    6 + 7 together mean `@testable` code lives in exactly ONE leaf test target, which is the constraint `Support/RealModelHarness.swift` already records.

    ## What that costs the split

    `FoundationModelsRouterEvals`'s machinery (the datasets, the evaluations, the report, the progress log) is used by its 72 hermetic tests AND by its 3 gated suites, so it has to move to a plain `.target` both can depend on. Measured by dropping `@testable` from the five machinery files and building: only ONE file fails, `CompactionEvalSeed.swift`, and only on two router symbols — `TranscriptTurns` and `Compactor.estimatedTokenCount(of:)`, both `internal`. `package` access is the fix, and it widens nothing outside this package.

    The integration target cannot be split the same way: its two hermetic suites test gated-only support (`RealModelHarness`, the gated suite's own scripted-turn fixture), and `RealModelHarness` needs about a dozen internal router initializers. Those 9 tests travel with their subject.

    ## The shared workflow

    `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` was read. Its `integration` job finds ONE `.xctest` bundle by glob, copies an mlx `default.metallib` beside it, and runs `<GATE_ENV>=1 xcrun xctest <bundle>`. Two facts follow: the interface cannot express target selection without the gate variable, and `integration-xctest-glob: "*IntegrationTests.xctest"` with `head -n 1` means the gated EVAL suites have never run in CI at all. The metallib copy is what `MetalLibraryTestBootstrap` now does from inside each gated process, and `MetalLibraryBootstrapIntegrationTests` is its proof, so the copy is no longer the only thing standing between a gated run and the shaders.
  timestamp: 2026-08-19T13:26:45.192143+00:00
- actor: claude-code
  id: 01m0d50t8186y4h46jypkevcmf
  text: |-
    Implementation landed. The shape, and what it cost.

    ## The targets

    | target | kind | holds |
    |---|---|---|
    | `FoundationModelsRouterRealModelTests` | `.testTarget` | the 13 real-model integration suites, renamed from `FoundationModelsRouterIntegrationTests` |
    | `FoundationModelsRouterRealModelEvals` | `.testTarget` | the 3 real-model eval suites and their runners, new |
    | `FoundationModelsRouterEvalSupport` | `.target` | the evals' machinery — datasets, evaluations, report, progress log, tier limits — new |
    | `FoundationModelsRouterEvals` | `.testTarget` | the 72 hermetic eval tests, unchanged in purpose |

    The two real-model target names share the `FoundationModelsRouterRealModel` prefix, and `--filter`/`--skip` take a regular expression over `<test-target>.<test-case>`, so ONE name selects or excludes both.

    ## The commands

    - everyday: `swift test --skip FoundationModelsRouterRealModel` — 1067 tests in 13 s
    - CI real model: `swift test --filter FoundationModelsRouterRealModel --skip CompactionEvalFullDataset`
    - the smoke tier alone: `swift test --filter CompactionSmoke`
    - the whole-dataset eval: `swift test --filter CompactionEvalFullDataset`

    Every one of them goes through `Scripts/swift-test.sh` in CI, which fails a run whose selectors matched no test — `swift test` reports that case as `warning: No matching test cases were run` and exits 0.

    ## What the env vars became

    All 16 `private let ...EnvVar` constants, their `!= nil` lookups and their `.enabled(if:)` traits are gone. `rg 'FM_ROUTER_'` and `rg '\.enabled\(if'` both come back empty over the whole repository. Three selectors replaced them, each named once: the target prefix, `CompactionSmoke` for the seconds-long tier the old `FM_ROUTER_COMPACTION_SMOKE` carried (two suites renamed so the three share it), and `CompactionEvalFullDataset` for the opt-in whole-dataset tier.

    ## What the split cost the router

    Four `internal` declarations became `package`, and nothing else: `TranscriptTurn`, `TranscriptTurns` (with `split`/`partition`), `Compactor.estimatedTokenCount(of: Transcript)`, and `Summarization.estimatedTokens(of: String)`. Each is named by the evals' machinery, which had to move to a plain target both eval targets can depend on, and a plain target cannot reach `internal` through `@testable`. `package` stops at this package's boundary, so the library's public surface is unchanged. Each carries a doc paragraph saying why it is `package`.

    ## CI

    `.github/workflows/ci.yml` no longer calls `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main`. That workflow's integration job takes the NAME of a gate variable and runs ONE `.xctest` bundle found by glob under `<VARIABLE>=1 xcrun xctest`, so it can express neither selector, and its `head -n 1` glob meant the gated EVAL suites had never run in CI at all. The replacement is two jobs in this repository, the real-model one `needs: test`. The shared workflow's metallib copy is dropped: `MetalLibraryTestBootstrap` installs that link from inside each real-model process and `MetalLibraryBootstrapIntegrationTests` proves the shaders load.

    ## The one gap, stated plainly

    `RealModelHarnessTests` (5 tests) and `ScriptedTurnSizingTests` (4) are hermetic but live in the real-model target, so `--skip FoundationModelsRouterRealModel` leaves them out. They cannot move: each tests real-model-only support (`RealModelHarness`, the round-trip suite's own scripted-turn fixture), `RealModelHarness` needs about a dozen `internal` router initializers, and a target two test targets depend on is compiled by `swift build -c release`, where `@testable` cannot resolve. They still run on every push, because the CI real-model job runs them. Filed as its own card.
  timestamp: 2026-08-19T13:57:52.513650+00:00
- actor: claude-code
  id: 01m0d538fa68pe199haabt7m9z
  text: |-
    ### implement — changed
    - evidence: 57 files — 5 added, 16 modified, 36 renamed. Verified: `swift build --build-tests` clean; `swift build -c release` clean (88.4 s); `Scripts/swift-test.sh --skip FoundationModelsRouterRealModel` green, 995 + 72 tests in 13 s, exit 0; `swift test --filter 'FoundationModelsRouterRealModelTests\.(RealModelHarnessTests|ScriptedTurnSizingTests)'` runs 9 tests in 2 suites, so a target-name selector reaches the suites inside the target; `swift test --filter FoundationModelsRouterRealModelEvals --skip CompactionEval --skip CompactionContinuity` reaches the evals target and reports `No matching test cases were run` at exit 0, and the same command through `Scripts/swift-test.sh` exits 1, as does `Scripts/swift-test.sh --filter FoundationModelsRouterRenamedAway`. No real-model suite was run.
    - next: `/review`
  timestamp: 2026-08-19T13:59:12.618051+00:00
position_column: doing
position_ordinal: '8280'
title: Gated real-model tests must be a CI-selectable package target, not 16 bespoke environment variables
---
From the user, 2026-08-19:

> i do want the gated run able to run as integration tests on CI, and am not really happy you did it with an environment variable rather than a separate integration test package target

## What is there now

**16 gated suites, each with its own environment variable**, spread across two test targets that also hold hermetic tests:

`Tests/FoundationModelsRouterIntegrationTests/` — 13 suites, each with a private env-var constant, a `!= nil` lookup and a suite-level `.enabled(if:)`:
`IntegrationTests`, `SessionTreeRestorationIntegrationTests`, `AutoCompactionTriggerIntegrationTests`, `CompactionSpikeIntegrationTests`, `LanguageModelSessionBackendTests`, `TranscriptReconstructionIntegrationTests`, `RealToolTurnComparisonTests`, `CompactionRoundTripIntegrationTests`, `CompactionSmokeIntegrationTests`, `RecordingHandleIntegrationTests`, `RecordedTranscriptCompactionIntegrationTests`, `PropagationProbeIntegrationTests`, `MetalLibraryBootstrapIntegrationTests`.

`Tests/FoundationModelsRouterEvals/` — 3 suites: the fact-retention subset, the whole-dataset tier, and the continuity tier.

Both targets ALSO hold hermetic tests that must keep running on every `swift test` — 37 in the integration target and 75 in the evals target as of `f1dd39e`. That mixing is the reason the gate ended up inside the file rather than at the target.

(Corrected while implementing: 37 and 75 are the TOTALS of each target. `swift test list` lists a suite that `.enabled(if:)` turns off, which is where those numbers came from. The hermetic counts are 9 of 37 and 72 of 75.)

## Why the environment variable is the wrong mechanism

- CI cannot select a suite. It has to know a variable name for each one, and the names are not discoverable from the package manifest.
- A run with the variable unset reports green while measuring nothing. That is the one-bit failure this board has already paid for repeatedly.
- The gate is invisible to `swift test --list-tests` and to any CI matrix built from the manifest.
- Three of the sixteen were added on 2026-08-19 by this session, which extended the pattern rather than questioning it.

## The constraint to settle FIRST, by measurement and not by memory

`swift test` runs every test target in the package. As far as this session knows there is no per-target opt-out in SwiftPM, so moving the gated suites into their own target gives CI a clean selector but does NOT stop a plain `swift test` from running them — which is the property the env var was buying.

Settle that before designing. Check, against the SwiftPM version this package uses:

- whether a `.testTarget` can be excluded from a default `swift test` run
- what `swift test --filter` and `swift test --skip` really select, and whether either takes a target name rather than a suite name
- whether a nested package under this repository, depending on the router by path, is the shape that gives both properties: invisible to the root `swift test`, and one command for CI

Do not assume the answer. Report what the tool really does.

## What to build once that is settled

A target (or nested package) that holds every real-model suite, so that:

- CI runs the heavy tests by naming one target, with no environment variable
- a plain `swift test` stays fast and hermetic, and does not silently skip anything
- a run that measures nothing cannot report green
- the hermetic tests in both current targets keep running on every `swift test`

Where a gate must still exist, there should be ONE, named once, not sixteen.

## Acceptance Criteria

- [x] The SwiftPM constraint above is settled by measurement, and what the tool really does is written down
- [x] Every real-model suite is selected by target rather than by an environment variable
- [x] CI can run the gated tests with one command that names no environment variable
- [ ] A plain `swift test` stays hermetic and fast, and the hermetic tests of both current targets still run — 72 of the 81 do, under `swift test --skip FoundationModelsRouterRealModel`, in 13 seconds. The other 9 test real-model-only support and travel with it; card ^cvsh3m9 carries what closing that costs.
- [x] A gated run that measures nothing fails rather than reporting green
- [x] The remaining gate, if any, is named once rather than sixteen times
#ci #test-debt