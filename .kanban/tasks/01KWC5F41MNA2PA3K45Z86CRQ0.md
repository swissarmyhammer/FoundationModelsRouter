---
depends_on:
- 01KWC5CDXEMC7DBSV8JV81ECY9
- 01KWC5DK4AXYHFBK2TJRPK88KW
- 01KWC5E1APGYR4D8G574H2KQ3F
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: todo
position_ordinal: '8980'
title: Router actor + resolve orchestration + ResolutionProgress (milestone 4b)
---
## What
The `Router` actor and its async `resolve`, wiring host profile + repo metadata + joint-fit into real model selection, download, and preload, while reporting UI-bindable progress. Plan "Access API", "Resolution" step 5, "Core Types" (`Router`, `ResolutionProgress`).

- `Sources/FoundationModelsRouter/Router.swift`:
  - `actor Router` with `let id: ULID` (recording root, time-sortable) and `init(id: ULID = .generate(), headroomReserve: Int64 = 4<<30, maxConcurrentForks: Int = 4, cacheDir: URL? = nil, recordingsDir: URL? = nil, recorder: TranscriptRecorder = .jsonl, recordingLevel: RecordingLevel = .full, redact: (@Sendable (String) -> String)? = nil)`.
    - `RecordingLevel { off, metadataOnly, full }` and the `redact` hook are CARRIED here but only ENFORCED in milestone 10b — define the enum + store the values now so the seam exists.
  - Holds the host-profile cache + repo-metadata cache.
  - `func resolve(_ def: ProfileDefinition, reporting: ResolutionProgress) async throws -> LanguageModelProfile`:
    1. compute budget (milestone 1, cached);
    2. size candidates from HF metadata (milestone 3) → footprints (milestone 2);
    3. joint-fit (milestone 4a) → chosen trio or throw `ResolutionFailure`;
    4. download chosen repos via `MLXHuggingFace` and load: `ModelContainer` for standard/flash (`MLXLLM`), embedder (`MLXEmbedders`); `preload()` all three;
    5. report `ResolutionProgress` through `sizing → downloading → loading → ready` (or `failed`).
- `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift`:
  - `@MainActor @Observable final class ResolutionProgress` with `Phase { sizing, downloading, loading, ready, failed(String) }`, `var phase`, `var fraction: Double`, `var slots: [ModelSlot: SlotProgress]`.
  - `struct SlotProgress { State { pending, sizing, downloading, loading, ready, failed(String) }; chosen: ModelRef?; bytesDownloaded; bytesTotal }`.
- `Sources/FoundationModelsRouter/LanguageModelProfile.swift` (storage only here):
  - `final class LanguageModelProfile { definitionName; standard: RoutedLLM; flash: RoutedLLM; embedding: RoutedEmbedder }` holding the loaded containers + each slot's `SlotResolution`. (Lifecycle/`release()` is milestone 5a; the session surface is milestone 5b.)
  - `RoutedLLM` / `RoutedEmbedder` defined as handles carrying `slot, chosen, footprintBytes, resolution`, the loaded container, **and `routerID: ULID` + a non-optional `TranscriptRecorder`** — both populated by the Router at resolve time so the handle can vend a recorded session/embed (their methods land in milestone 5a/5b).

## Acceptance Criteria
- [ ] With injected host profile + metadata + a stubbed loader, `resolve` selects the joint-fit trio and advances `ResolutionProgress` `sizing → downloading → loading → ready`; `fraction` ends at 1.0; each `SlotProgress.chosen` is set and `state == ready`.
- [ ] An unsatisfiable profile sets `phase == .failed(...)` and throws `ResolutionFailure` with per-slot diagnostics.
- [ ] Progress mutations occur on the main actor (ResolutionProgress is `@MainActor`).
- [ ] `Router.id` is a fresh ULID per construction unless one is passed in.
- [ ] Each vended `RoutedLLM`/`RoutedEmbedder` carries the Router's `id` (routerID) and the Router's `TranscriptRecorder`.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ResolveTests.swift` (Swift Testing) using injected probe/metadata and a stub model loader (no real download): success path drives progress phases + populates the profile; failure path throws `ResolutionFailure` and sets `.failed`; passed-in `id` is retained; handles carry routerID + recorder. Real model loading is covered by the gated integration suite (milestone 7).
- [ ] Run `swift test --filter ResolveTests` — all pass.

## Workflow
- Use `/tdd` — write failing progress-phase + selection + handle-wiring tests with a stubbed loader first.