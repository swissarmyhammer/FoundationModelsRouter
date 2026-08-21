---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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

- [ ] Each of the 4 declarations has a recorded compiler rename probe, with the root build green and the `IntegrationTests` build naming the use sites
- [ ] Each proven-live declaration carries `// periphery:ignore` with its reason on the line above
- [ ] The scan above reports 0 findings across the whole root package
- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` stays clean in BOTH packages, and root `swift test` stays green #compaction #real-model #tech-debt