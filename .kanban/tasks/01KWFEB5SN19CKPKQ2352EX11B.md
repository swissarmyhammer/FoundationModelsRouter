---
depends_on:
- 01KWFDEMZ9ZGWQHFFWWYRJV0PV
position_column: todo
position_ordinal: '80'
title: 'ResolutionProgress: real incremental byte-percentage during download'
---
## What
The download-progress plumbing already exists but its live byte-percentage is unproven and can regress, which matters most for large models (multi-GB weights). Make `ResolutionProgress` surface true, monotonic, incremental download percentage and prove it with automated tests.

Current state (already implemented — do NOT rebuild):
- `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift` — `SlotProgress.bytesDownloaded`/`bytesTotal`; `progressFraction` returns `0.5 * bytesDownloaded/bytesTotal` while `.downloading` (0 when `bytesTotal == 0`); `refreshFraction()` averages slots.
- `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift` — `DownloadProgress { bytesDownloaded, bytesTotal, fraction }`; `loadLLM`/`loadEmbedder(…, reporting:)`.
- `Sources/FoundationModelsRouter/Router.swift` — `reporter(slot:progress:)` (~L497-507): on each `DownloadProgress` it does `Task { @MainActor in … sp.bytesDownloaded = dp.bytesDownloaded; sp.bytesTotal = dp.bytesTotal; progress.refreshFraction() }`, guarded by `sp.state == .downloading`.
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` — `handler(_:)` (~L331-340) maps Foundation `Progress.completedUnitCount`/`totalUnitCount` → `DownloadProgress`.

Gaps to close:
1. **Monotonicity (Router.swift `reporter`)**: each tick is a separate `Task { @MainActor }`, so ticks can apply out of order and the visible `bytesDownloaded`/`fraction` can go backward mid-download. Make the update monotonic — ignore a tick whose `bytesDownloaded` is less than the slot's current value (`sp.bytesDownloaded = max(sp.bytesDownloaded, dp.bytesDownloaded)`), and adopt `bytesTotal` when it becomes known (`> 0`). Keep the `state == .downloading` guard so late ticks can't clobber a slot already moved to loading/ready.
2. **Live unit fidelity (LiveModelLoader.swift `handler`)**: confirm the Foundation `Progress` from the Hub downloader reports BYTES (not file counts). If `completedUnitCount`/`totalUnitCount` are byte counts, keep and document that in the doc comment; if the source only provides `fractionCompleted`, derive bytes from the model's known total (or record fraction faithfully) so the surfaced percentage is byte-accurate for huge models. Do not fabricate a fake total.

## Acceptance Criteria
- [ ] Feeding a stub loader that emits several ascending `DownloadProgress` ticks (e.g. 0/8GB, 2GB/8GB, 5GB/8GB, 8GB/8GB) drives `progress.slots[slot].bytesDownloaded`/`bytesTotal` to the latest values and makes `progress.fraction` strictly increase across the ticks while `.downloading`.
- [ ] An out-of-order or regressing tick (a lower `bytesDownloaded` after a higher one) does NOT reduce `slots[slot].bytesDownloaded` or `fraction` (monotonic).
- [ ] A late tick arriving after the slot has left `.downloading` (now `.loading`/`.ready`) is ignored (existing guard preserved).
- [ ] `LiveModelLoader.handler`'s `Progress`→`DownloadProgress` mapping is documented as byte-based (or corrected to be byte-accurate); no behavior regression to existing tests.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ResolveTests.swift` — ADD a new `@Test` (do not refactor existing tests) using a stub loader whose `loadLLM`/`loadEmbedder` invoke `reporting(_:)` with multiple ascending ticks (large byte totals). Deterministically synchronize the async `Task { @MainActor }` updates (await a signal / poll the observable), then assert `bytesDownloaded`/`bytesTotal` and a strictly-increasing `fraction` during `.downloading`.
- [ ] `Tests/FoundationModelsRouterTests/ResolveTests.swift` — ADD a `@Test` firing a regressing tick after a higher one and assert `bytesDownloaded`/`fraction` do not decrease.
- [ ] `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift` — in the gated real-model suite, assert that during download the embedding/standard slot observes `bytesTotal > 0` and `bytesDownloaded` reaches `bytesTotal` (real byte percentage, not a single 0→100 jump).
- [ ] Run `swift test` (env `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — full unit suite green; gated integration suite skips by default.

## Workflow
- Use `/tdd` — write the incremental + monotonic progress tests first (they should fail against the current single-tick behavior / lack of a monotonic guard), then implement the `reporter` hardening to make them pass.