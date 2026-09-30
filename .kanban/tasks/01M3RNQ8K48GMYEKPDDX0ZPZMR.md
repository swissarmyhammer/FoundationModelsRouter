---
comments:
- actor: claude-code
  id: 01m3rqaym2a46s2sbpw11a4pyj
  text: |-
    Research (implement):
    - Extras bbf9717 is in Package.resolved and IntegrationTests/Package.resolved. The Router does not compile against it: LiveModelLoader.downloadProgress(of:) and the test RecordingPoolLoader use `.downloading(fraction:)`.
    - The Router PooledModelLoader types in Sources are LiveModelLoader and SlotPoolLoader. Both implement only load(_:), so the pool stream gets only `.loading` from them.
    - Decision: resolution progress keeps ONE path, the loader callback (Router.reporter through SlotPoolLoader.reporting). The Router does not subscribe to ModelPool.progress(for:). The resolve already sets downloading, loading (before preload) and ready.
    - SlotPoolLoader gets load(key:progressHandler:). It gives each DownloadProgress of the router loader to the resolve callback and to the pool handler as `.downloading(completedBytes:totalBytes:)`. When a download has all its bytes, it also reports `.loading`. The pool adds `.loading` before `.ready` when no loader reported it (cached model).
    - LiveModelLoader gets load(key:progressHandler:). It forwards the handler to the model loader (MLXModelLoader) and also gives each download to the init `reporting`. load(_:) calls it with an empty handler. The router paths map `.downloading(completedBytes:totalBytes:)` to DownloadProgress with real bytes. progressScale is deleted.
    - No `swift package update` and no push in this step (orchestrator order).
  timestamp: 2026-09-30T08:36:43.266312+00:00
- actor: claude-code
  id: 01m3rsam1ww2cs3p0a5yebzzhv
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Resolution/SlotPoolLoader.swift, Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift. RED: `swift test --filter SlotPoolLoaderTests` 16 tests, 9 issues (scaled bytes, pool stream had only `.loading`). GREEN: same filter 16 tests passed. Full `swift test`: 1427 tests in 178 suites passed (2 known issues are the intentional harness tests). `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests`: 49 tests in 22 suites passed. `--filter FoundationModelsRouterEvalIntegrationTests`: 1 test passed. No Swift compiler warnings.
    - Extras revision bbf9717 is in both Package.resolved files. By order of the orchestrator, no `swift package update`, no commit and no push in this step. Thus the box "CI is green on the pushed commit" stays open for the commit step.
    - next: /review
  timestamp: 2026-09-30T09:11:29.596068+00:00
position_column: doing
position_ordinal: '80'
title: Resolution progress from the pool stream with real bytes; remove the fixed progress scale
---
**Wait for:** FoundationModelsExtras task 01M3RNQ63F2391R715W156WGBX ("Pool progress for every load, with real byte counts"): done, pushed as bbf9717.

## What
- **The cause (found by the Extras session):** `ModelPool` already publishes every acquire path. `SlotPoolLoader` gives no progress because it implements only `load(_:)`. Implement `load(key:progressHandler:)` in `SlotPoolLoader` (and each Router `PooledModelLoader`) and pass the handler through to `MLXModelLoader`.
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: map `ModelLoadProgress.downloading(completedBytes:totalBytes:)` to `DownloadProgress` with real bytes; delete `LiveModelLoader.progressScale`.
- Where it is simpler, subscribe to `ModelPool.progress(for:)` for a resolve in place of the loader callback; choose one path, not both.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [x] `DownloadProgress` bytes are the real bytes of the download.
- [x] `progressScale` does not exist.
- [x] Resolution progress still reports downloading, loading and ready.
- [ ] CI is green on the pushed commit.

## Tests
- [x] A Router unit test with a test loader that reports bytes: `DownloadProgress` has those bytes.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool