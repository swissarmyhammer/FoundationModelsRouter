---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gk2wbvddb1pcaeb6qq76m1
  text: |-
    Research: LiveModelLoader (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift) holds `modelLoader: any PooledModelLoader` (MLXModelLoader in the public init; MLXModelLoader.footprintBytes(of:) sums the .safetensors files of the snapshot folder). The Extras pool calls loader.footprintBytes(of:) only on the measured path, ModelPool(loader:).acquire(key) -> loadMeasured; acquire(_:footprintBytes:sessionBytes:loader:) never measures, which is why the Router path was unaffected. Reused the existing private RecordingPoolLoader stub in SlotPoolLoaderTests (the "live loader" section) instead of a new helper: it now records measured keys and measures a fixed 4_321 bytes (distinct from the suite's 1_000 caller footprint).

    TDD: new test `poolCountsFootprintOfLiveLoaderModelLoader` builds ModelPool(loader: LiveModelLoader(modelLoader: RecordingPoolLoader)) and acquire(key). RED: measuredKeys == [] and resident footprint not the measured value (default 0). GREEN after adding `public func footprintBytes(of:)` forwarding to modelLoader. Full `swift test`: 2081 tests in 257 suites passed (9 known issues are pre-existing withKnownIssue tests in other files), plus the 36- and 19-test runs passed; `swift build --build-tests` has no compiler warnings (only the SwiftPM "missing creator for mutated node" mlx bundle notice, unrelated).
  timestamp: 2026-10-22T01:19:52.699178+00:00
- actor: claude-code
  id: 01m5gk2xz8x0w94ggxsyt6x2d3
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift (new `footprintBytes(of:)`), Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift (RecordingPoolLoader measures; new pool test). swift test: 2081/257 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-10-22T01:19:54.344984+00:00
- actor: claude-code
  id: 01m5gkbk7f6z2y2xch0t6vnkza
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4e903a70) — 0 findings (confirmed 0, refuted 0; 7 validator passes attempted, 0 failed); 2 source files reviewed (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift); .kanban/ excluded by .reviewignore. No prior Review Findings sections.
    - next: none — task moved to done
  timestamp: 2026-10-22T01:24:38.255793+00:00
- actor: claude-code
  id: 01m5gkcbzdn55mb3xtpgcz7gff
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — LiveModelLoader.swift, SlotPoolLoaderTests.swift
    - test: green — swift test, 2081/36/19
    - commit: 4e903a70
    - review: clean — 0 findings
  timestamp: 2026-10-22T01:25:03.597014+00:00
position_column: done
position_ordinal: ffffffffab80
title: LiveModelLoader gives the footprint of its model loader to an Extras pool
---
## What
`LiveModelLoader` conforms to `PooledModelLoader`, but it does not implement `footprintBytes(of:)`. Thus it uses the Extras default, which gives 0. An application that gives a `LiveModelLoader` to an Extras `ModelPool` (the type doc tells about this use) gets a footprint of 0 bytes for each model, and the budget of the pool counts no weights.

The Router path does not use this measure: `SlotPoolLoader` gives `footprintBytes` to `admission.acquire`. The gap is only on the direct pool path.

Found during ^1056ce6.

## Acceptance Criteria
- [x] `LiveModelLoader.footprintBytes(of:)` gives the value of its model loader (`MLXModelLoader` measures the weights in its cache folder).

## Tests
- [x] A unit test with a stub model loader that gives a known footprint, through a `LiveModelLoader`.
- [x] `swift test` passes with zero failures and zero warnings.