---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0hdg3g3j1pbaaqv4q1dg9vz
  text: |-
    ## Compiler rename probes

    I read `code-hygiene/dead-code-swift` first. The rule's own command over the whole tree gave the same 4 findings the card names — no more, no less.

    Store: `.build/out` (the `.build/debug/index/store` location does not exist on this toolchain). Test target paths from `swift package describe --type json`: `Tests/FoundationModelsRouterTests` and `Tests/FoundationModelsRouterEvals` only. The two `.target`s `FoundationModelsRouterRealModelSupport` and `FoundationModelsRouterEvalSupport` are not excluded, as the card states.

    ### Probe 1 — `CompactionFold.run(_:summarization:container:label:)` — LIVE

    Renamed to `runProbeRenamed`.
    - Root `swift build --build-tests`: green, 0 errors. Periphery is correct that the root package has no caller.
    - `swift build --package-path IntegrationTests --build-tests`: FAILED.
      `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordedTranscriptCompactionIntegrationTests.swift:284:48: error: type 'CompactionFold' has no member 'run'`
    - The second use site is `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift:372`. The build stops at the first file, thus only one file is named in the log; a grep shows both call sites.

    Restored.

    ### Probe 2 — `RealModelContainer.load(ref:context:samplingMode:)` — LIVE

    Renamed to `loadProbeRenamed`.
    - Root build: green, 0 errors.
    - IntegrationTests build: FAILED with 4 errors of
      `error: type 'RealModelContainer' has no member 'load'`, e.g.
      `CancelledGenerationTeardownIntegrationTests.swift:60:54` and `:105:53`.
    - A grep finds 15 call sites in the IntegrationTests package, across 10 files:
      `SessionTreeRestorationIntegrationTests` (4), `LanguageModelSessionBackendTests` (7),
      `CompactionRoundTripIntegrationTests` (2), `CancelledGenerationTeardownIntegrationTests` (2),
      `PropagationProbeIntegrationTests` (2), `AutoCompactionTriggerIntegrationTests`,
      `CompactionSpikeIntegrationTests`, `TranscriptReconstructionIntegrationTests`,
      `RealToolTurnComparisonTests` (2), `RecordingHandleIntegrationTests`,
      `RecordedTranscriptCompactionIntegrationTests`, `CompactionSmokeIntegrationTests`.

    Restored.

    ### Probe 3 — `MLXFoundationModelsSessionBackend.session` — LIVE

    Renamed to `sessionProbeRenamed`.
    - Root build: green, 0 errors, all 79 products.
    - IntegrationTests build: FAILED.
      `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift:124:44: error: value of type 'MLXFoundationModelsSessionBackend' has no member 'session'`
      and the same at `:141:42`.

    Restored.

    ### Probe 4 — `CountingBlankSlateSummarizer.init(container:)` — LIVE INSIDE THE ROOT PACKAGE

    This probe is not the same as the other three, and it gives a different answer.

    Renamed the argument label to `init(containerProbeRenamed container:)`.
    - Root `swift build --build-tests`: FAILED.
      `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift:184:54: error: incorrect argument label in call (have 'container:', expected 'containerProbeRenamed:')`

    The caller is `CompactionFold.run`, in the same file, in the same package. Thus the initializer is a transitive casualty of `run`, exactly as the card predicted — the same shape as `compactionContinuityFastKeepRecentTurns` on ^m03heaa. It gets NO marker.

    Restored.

    ## What each declaration got

    | declaration | verdict | action |
    |---|---|---|
    | `CompactionFold.run(_:summarization:container:label:)` | live, used only from IntegrationTests | `// periphery:ignore` with the reason above it |
    | `RealModelContainer.load(ref:context:samplingMode:)` | live, used only from IntegrationTests | `// periphery:ignore` with the reason above it |
    | `MLXFoundationModelsSessionBackend.session` | live, used only from IntegrationTests | `// periphery:ignore` with the reason above it |
    | `CountingBlankSlateSummarizer.init(container:)` | live, used inside the root package | nothing — a transitive casualty of `run` |

    Nothing was deleted. No probe showed a genuinely unreferenced declaration.

    ## `MLXFoundationModelsSessionBackend.session` in `Sources/` — the judgement I applied

    The card asks whether this belongs in `Sources/` at all. It does, and here is the reasoning rather than a marker put over the question:

    - The stored property it reads, `liveSession`, is `private`. `@testable import` raises `internal` to visible; it does not raise `private`. Thus no declaration outside this type can read `liveSession`, and the accessor cannot move into the test package or into an extension in another module.
    - The accessor is `internal`, thus it is not on the package's public surface. No consumer of the library can reach it. What it costs production is one computed property that forwards.
    - The alternative that would remove the accessor is to widen the stored property to `internal let liveSession`. That is a wider change to production state than the accessor is, and it is not what this card orders. I did not make it.

    I extended the existing doc comment with that reasoning, then put the marker on the line above the declaration, as the rule's staging contract requires.

    ## Re-scan after the markers

    Marked the two chain roots and `session`, rebuilt, and ran the scan again. The `init(container:)` finding cleared on its own, with no marker on it — thus the validator keeps its sight of that initializer if `run` is ever deleted.

    Scan: 4 findings before, 0 findings after, across the whole root package.
  timestamp: 2026-08-21T05:42:59.843490+00:00
- actor: claude-code
  id: 01m0hdha9229xqrqbnxzrbghtv
  text: |-
    ### implement — changed
    - evidence: 3 files — `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`, `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift`, `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`. Each change is a `// periphery:ignore` marker with its reason on the comment lines above it; no code moved and nothing was deleted. Probes: `CompactionFold.run`, `RealModelContainer.load` and `MLXFoundationModelsSessionBackend.session` each kept the ROOT build green and broke the `IntegrationTests` build at the use sites (live); `CountingBlankSlateSummarizer.init(container:)` broke the ROOT build at `CompactionFold.swift:184` (a transitive casualty of `run`, thus no marker). Scan: 4 findings before, 0 after. `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0 in the root package and exit 0 in `IntegrationTests`. Root `swift test` exit 0: 1025 tests in 96 suites passed with 1 known issue, and 77 tests in 9 suites passed.
    - next: `/review`. No gated real-model run is needed. The open question on ^k0d30s4 is untouched, and nothing is committed.
  timestamp: 2026-08-21T05:43:39.554840+00:00
position_column: doing
position_ordinal: '8180'
title: Stage the four remaining dead-code-swift findings the two-package split causes, outside the EvalSupport target
---
Commit 1db2b56 moved the real-model tests into a nested `IntegrationTests` package. `code-hygiene/dead-code-swift` runs `periphery` with a workspace scope, and the rule states the limit in its own words: "The scope is `workspace` because periphery reads a whole package's index." The second package has its own index, and the scan at the root never reads it.

The result is one cause: a declaration in the ROOT package whose only consumer is in the `IntegrationTests` package always reports as dead.

Task ^m03heaa swept that cause through `Tests/FoundationModelsRouterEvalSupport`, where its own finding stood. It marked 9 declarations with `// periphery:ignore` and a reason. Four findings of the same cause stay open in two other places, which ^m03heaa did not touch:

| finding | only consumer |
|---|---|
| `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift:48` `function.constructor `init(container:)`` | reached through `CompactionFold.run` below |
| `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift:178` `function.method.static `run(_:summarization:container:label:)`` | `IntegrationTests/.../RecordedTranscriptCompactionIntegrationTests.swift:289`, `CompactionSmokeIntegrationTests.swift:377` |
| `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift:55` `function.method.static `load(ref:context:samplingMode:)`` | 6 sites in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/` |
| `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:301` `var.instance `session`` | its own doc comment states it: "Test-only accessor onto ``liveSession``, for `@testable import` in the gated integration suite" |

## What to build

- Run a compiler rename probe on each, the way the project rule
  [[dead-code-validator-false-positives-mainswift]] states: rename the declaration, build the ROOT package (it must stay green, which proves periphery is right about the root), then build `IntegrationTests` (it must fail at the use sites, which proves the symbol is live). Restore each rename.
- Mark each proven-live declaration with `// periphery:ignore`, with the reason on its own comment line above the marker. The marker takes no trailing text. Use the wording ^m03heaa established in `Tests/FoundationModelsRouterEvalSupport`: name the consumer, then state that periphery reads only this package's index.
- Delete nothing the probe does not show to be truly unreferenced.
- Note that `CompactionFold.init(container:)` may be a transitive casualty of `CompactionFold.run`, the way `compactionContinuityFastKeepRecentTurns` and `compactionEvalReasoningTokenHeadroom` were casualties of `compactionContinuityFastSummarization` on ^m03heaa. Mark the chain root first, run the scan again, and add a marker only where one is still necessary.

## How to measure

The rule's own command, which ^m03heaa recorded:

```
swift build --build-tests
periphery scan --quiet --format json --skip-build --index-store-path .build/out \
  --retain-public --retain-objc-accessible --retain-swift-ui-previews \
  --retain-codable-properties --disable-update-check --relative-results \
  --report-exclude 'Tests/FoundationModelsRouterTests/**' \
  --report-exclude 'Tests/FoundationModelsRouterEvals/**'
```

The two `--report-exclude` globs are what the rule's script derives from `swift package describe --type json`, which excludes only targets of type `test`. `FoundationModelsRouterRealModelSupport` and `FoundationModelsRouterEvalSupport` are plain `.target`s, so neither is excluded.

## Acceptance Criteria

- [x] Each of the 4 declarations has a recorded compiler rename probe, with the root build green and the `IntegrationTests` build naming the use sites
- [x] Each proven-live declaration carries `// periphery:ignore` with its reason on the line above
- [x] The scan above reports 0 findings across the whole root package
- [x] `swift build --build-tests -Xswiftc -warnings-as-errors` stays clean in BOTH packages, and root `swift test` stays green

## Probe results

Three declarations are live only from the `IntegrationTests` package, and each got a marker:

- `CompactionFold.run(_:summarization:container:label:)`
- `RealModelContainer.load(ref:context:samplingMode:)`
- `MLXFoundationModelsSessionBackend.session`

The fourth, `CountingBlankSlateSummarizer.init(container:)`, is different. Its rename made the ROOT build fail at `CompactionFold.swift:184`, thus its caller is in the same package and the finding was a transitive casualty of `run`. It got no marker, and it cleared by itself once `run` was marked.

Nothing was deleted. No probe showed a genuinely unreferenced declaration. #compaction #real-model #tech-debt