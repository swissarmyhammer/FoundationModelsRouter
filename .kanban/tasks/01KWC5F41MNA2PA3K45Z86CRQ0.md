---
comments:
- actor: wballard
  id: 01kwd2kpw8h4gmbdfe847rebea
  text: 'Picked up. Researched existing APIs (JointFit.resolve, RepoMetadataReader, HostProfile/Cache, MachineProbe, MetadataSource, TranscriptRecorder protocol, ULID) and the MLX package APIs in .build/checkouts/mlx-swift-lm: LLM load via free fn loadModelContainer(from: any Downloader, using: any TokenizerLoader, configuration: ModelConfiguration(id:revision:), progressHandler: (Progress)->Void) -> ModelContainer; embedder via EmbedderModelFactory.shared.loadContainer(from:using:configuration:.init(id:),progressHandler:) -> EmbedderModelContainer; downloader/tokenizer from MLXHuggingFace macros #hubDownloader()/#huggingFaceTokenizerLoader(). Plan: inject ModelLoader protocol (marker protocols LoadedLLMContainer/LoadedEmbeddingContainer conformed by ModelContainer/EmbedderModelContainer); LiveModelLoader does the real wiring; StubModelLoader in tests. recorder init param will be optional (resolved to .jsonl(recordingsDir) or .none) since a literal .jsonl default can''t reference recordingsDir.'
  timestamp: 2026-06-30T20:12:58.632313+00:00
- actor: wballard
  id: 01kwd34sdaxktjv1ez4p6bh2mg
  text: |-
    Implemented TDD (RED confirmed via missing-type compile errors, then GREEN). New files:
    - Sources/.../Router.swift: actor Router (nonisolated let id), RecordingLevel{off,metadataOnly,full}, stores headroomReserve/maxConcurrentForks/cacheDir/recordingsDir/recorder/recordingLevel/redact + injected probe/metadataReader/loader + host-profile cache. resolve(): beginSizing -> hostBudget (HostProfileCache+probe) -> sizeCandidates (slot-aware: embedding sized weights-only via Footprint.embedder, generation via metadata.footprint.footprint(context:)) -> JointFit.resolve (throws ResolutionFailure recorded to progress.phase=.failed) -> markChosen -> downloading (loader.loadLLM/loadEmbedder, byte reporting) -> loading (loader.preload, per-slot ready) -> complete (phase=.ready, fraction=1.0). All progress mutations via await MainActor.run.
    - Resolution/ResolutionProgress.swift: @MainActor @Observable ResolutionProgress + SlotProgress with progressFraction (download=first half, load=second half) and refreshFraction().
    - LanguageModelProfile.swift: LanguageModelProfile + RoutedLLM/RoutedEmbedder (final class, Sendable) carrying slot, chosen, footprintBytes(=chosen report's x1.2 estimate), resolution, container, routerID, recorder.
    - Resolution/ModelLoader.swift: ModelLoader protocol (loadLLM/loadEmbedder/preload), DownloadProgress, marker protocols LoadedModelContainer/LoadedLLMContainer/LoadedEmbeddingContainer.
    - Resolution/LiveModelLoader.swift: real MLX wiring via loadModelContainer(from:using:configuration:progressHandler:) and EmbedderModelFactory.shared.loadContainer(...); conforms ModelContainer/EmbedderModelContainer to the markers.

    LIVE-MLX NOTE for reviewer: this fork of mlx-swift-lm (mlx-foundationmodels branch) intentionally does NOT bundle a default Hub client. The MLXHuggingFace #hubDownloader()/#huggingFaceTokenizerLoader() macros expand to code referencing HuggingFace/HubClient/Tokenizers modules from swift-huggingface + swift-transformers, which are NOT in this package's dependency graph (the fork's own integration project adds them). Per the fork's design ("integration packages inject their own Downloader and TokenizerLoader"), LiveModelLoader takes an injected `Downloader` + `TokenizerLoader` and uses the core loader API. Router's default loader is UnconfiguredModelLoader (throws .notConfigured) so out-of-box resolve can size/joint-fit but real loading requires a configured LiveModelLoader (the gated milestone-7 integration suite wires the Hub-backed instances) or a test stub. This was the cleanest honest option without adding two external SPM deps. Flagging for reviewer to confirm whether adding swift-huggingface/swift-transformers belongs in milestone 7 instead.

    Also fixed a latent race: the byte-progress reporter dispatches Task{@MainActor} (unordered vs awaited phase hops), so it now only applies while the slot is still .downloading and never clobbers a terminal state.

    Recorder init param made `(any TranscriptRecorder)? = nil` (resolved to JSONL(recordingsDir) or NoneRecorder) since a literal `.jsonl(...)` default can't reference the recordingsDir param.

    Tests green: swift build OK; swift test --filter ResolveTests = 5/5; full swift test = 52 unit tests + 1 gated placeholder, no errors/warnings (only an unrelated mlx-swift_Cmlx.bundle build-infra warning). Left in `doing` for review.
  timestamp: 2026-06-30T20:22:18.282833+00:00
- actor: wballard
  id: 01kwd3ka240y5hg4jtyxgbbbrs
  text: |-
    Adversarial double-check (advisory) returned REVISE with 1 medium + 2 low findings; all addressed:
    1. (Medium) Download/load/preload failures didn't move ResolutionProgress to .failed, leaving a bound UI stranded mid-pipeline. FIXED: resolve now wraps the download->loading->complete section in do/catch; recordLoadFailure(_:progress:) sets phase=.failed(message) and marks every non-ready slot .failed before rethrowing. New test loaderFailureSetsPhaseFailed (uses the UnconfiguredModelLoader default that throws .notConfigured at load) asserts resolve throws ModelLoaderError and progress.phase==.failed with the in-flight slot .failed.
    2. (Low) Fraction math untested. FIXED: added slotProgressFractionMath (covers pending/sizing/failed=0, downloading 0/0.25/0.5, unknown-total=0, loading=0.5, ready=1) and refreshFractionAverages (mean of slot fractions).
    3. (Low) Misleading throws + force-unwrap on chosenRef. FIXED: removed chosenRef; downloadLLM/downloadEmbedder now take the non-optional resolution.standard/.flash/.embedding refs directly. slotResolution keeps its force-unwrap with a doc comment noting it's total by construction on the success path.

    Verification after revisions: swift build clean; swift test --filter ResolveTests = 8/8; full swift test = 55 tests + 1 gated, no errors/warnings (only the unrelated mlx-swift_Cmlx.bundle infra warning). Still in `doing`, ready for /review.
  timestamp: 2026-06-30T20:30:14.084307+00:00
depends_on:
- 01KWC5CDXEMC7DBSV8JV81ECY9
- 01KWC5DK4AXYHFBK2TJRPK88KW
- 01KWC5E1APGYR4D8G574H2KQ3F
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: doing
position_ordinal: '80'
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