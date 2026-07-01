---
comments:
- actor: wballard
  id: 01kwfkgcsqm9bnweytbn6e1b66
  text: |-
    Implemented TDD. Two production changes:

    1. Router.reporter (Router.swift): monotonic — `sp.bytesDownloaded = max(sp.bytesDownloaded, dp.bytesDownloaded)`, adopt `bytesTotal` only when `> 0`, kept the `state == .downloading` guard. Reporter made internal for direct test driving.

    2. LiveModelLoader.handler (LiveModelLoader.swift): LIVE-PROGRESS FINDING — the injected Hub downloader (`#hubDownloader()` -> swift-huggingface `HubClient.downloadSnapshot`) builds a byte-weighted Foundation Progress: `totalUnitCount` = sum of file byte sizes (real byte total), children weighted by byte size. BUT Foundation only aggregates a parent-with-children Progress through `fractionCompleted`; the parent's `completedUnitCount` counts only WHOLE completed children — a streaming multi-GB shard reads 0 until it finishes then jumps by its full size (verified empirically: parent completed stays 0 at a child's 50%, jumps on child completion). So the old `completedUnitCount` mapping WAS the exact single 0->100 jump the task warns about. Fixed: `bytesTotal = totalUnitCount` (real byte total, unchanged) and `bytesDownloaded = round(fractionCompleted * totalUnitCount)` — byte-accurate incremental, reaching exactly bytesTotal at completion. Handler made internal + fully documented.

    Tests (all new @Test, no existing test refactored):
    - ResolveTests.swift: ascending monotonic ticks (strictly increasing fraction), regressing tick ignored (bytes+total+fraction never decrease), late-tick-after-.loading ignored. Deterministic sync via a main-actor flush barrier (`await Task { @MainActor in }.value`), no sleep.
    - LiveModelLoaderTests.swift (new file): drives handler with a byte-weighted Progress tree, proves byte-accurate incremental mapping (RED with completedUnitCount, GREEN with fractionCompleted).
    - IntegrationTests.swift (gated): DownloadByteObserver + DownloadObservingLoader wrapper assert each downloaded slot sees bytesTotal>0 and bytesDownloaded reaches bytesTotal.

    Verify: `swift build` clean; full `swift test` = 128 unit tests pass, gated integration suite skipped by default. GREEN, left in doing.
  timestamp: 2026-07-01T19:46:44.663172+00:00
- actor: wballard
  id: 01kwfmx46eva9v2amm85h8d1mv
  text: 'Addressed all 7 review findings (2026-07-01 14:52) — doc-comment-only, no behavior change. Added formal DocC sections (`- Parameters:`/`- Parameter:`/`- Returns:`/`- Throws:`) to: LiveModelLoader `respond(to:instructions:following:)`, `loadLLM`, `loadEmbedder`, `handler`, `UnconfiguredModelLoader.loadLLM`, `UnconfiguredModelLoader.loadEmbedder`; and Router `reporter(slot:progress:)`. Matched existing style (Router.init / resolve param blocks). Verified: `swift build` clean (no new warnings), `swift test` green — 128/128 unit tests pass, gated integration suite skips by default. All 7 finding checkboxes flipped to [x]. Task left in `doing` for /review.'
  timestamp: 2026-07-01T20:11:10.414511+00:00
depends_on:
- 01KWFDEMZ9ZGWQHFFWWYRJV0PV
position_column: done
position_ordinal: '9780'
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

## Review Findings (2026-07-01 14:52)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:45` — The `respond(to:instructions:following:)` function has three parameters and a non-`Void` return type, but lacks formal documentation sections. The rule requires `- Parameters:` block and `- Returns:` section for functions with multiple parameters and non-void returns. Add a formal `- Parameters:` block documenting `prompt`, `instructions`, and `grammar`, plus a `- Returns:` section, following the structure demonstrated in `Router.init()` documentation.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:232` — The `loadLLM(_:slot:context:reporting:)` function has four parameters and a non-`Void` return type, but lacks formal documentation sections. Functions with multiple parameters require a `- Parameters:` block. Add a formal `- Parameters:` block documenting all four parameters and a `- Returns:` section.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:241` — The `loadEmbedder(_:slot:reporting:)` function has three parameters and a non-`Void` return type, but lacks formal documentation sections. Functions with multiple parameters require a `- Parameters:` block. Add a formal `- Parameters:` block documenting all three parameters and a `- Returns:` section.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:310` — The `handler` static function has one parameter (`reporting`) and a non-`Void` return type, but lacks formal documentation sections. The rule requires `- Parameter reporting:` and `- Returns:` sections, not just prose explanation. Add formal `- Parameter reporting:` and `- Returns:` sections within the existing doc comment, following the style used in other functions like `Router.init()` at Router.swift:89-92.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:323` — `UnconfiguredModelLoader.loadLLM(_:slot:context:reporting:)` has four parameters and throws, but lacks formal documentation sections. Public functions with multiple parameters require `- Parameters:` block and `- Throws:` section. Add a formal `- Parameters:` block for all four parameters, `- Returns:` section, and `- Throws:` section.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:331` — `UnconfiguredModelLoader.loadEmbedder(_:slot:reporting:)` has three parameters and throws, but lacks formal documentation sections. Public functions with multiple parameters require `- Parameters:` block and `- Throws:` section. Add a formal `- Parameters:` block for all three parameters, `- Returns:` section, and `- Throws:` section.
- [x] `Sources/FoundationModelsRouter/Router.swift:418` — The `reporter` static function has two parameters (`slot` and `progress`) and a non-`Void` return type, but lacks formal documentation sections. The rule requires a `- Parameters:` block and `- Returns:` section. Add a formal `- Parameters:` block documenting `slot` and `progress`, and a `- Returns:` section, following the structure demonstrated in the `init` method's documentation.