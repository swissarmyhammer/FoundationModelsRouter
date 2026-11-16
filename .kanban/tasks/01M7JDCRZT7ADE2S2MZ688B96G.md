---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jdps1q8jym9gqwew9wk068
  text: |-
    Research and implementation:
    - Stopped this repo's sourcekit-lsp (pid 27500), ran `swift package --manifest-cache local update FoundationModelsExtras`. Checkout is at 2f64483 (no newer commit on origin/main).
    - API decision: `LiveModelLoader.init(reporting:cacheDirectory:tokenProvider:speculativeDecoding:offline:)` has a new last parameter `offline: Bool? = nil`, given to `HubModelLoader(offline:)`. `nil` keeps the current behavior (reads `HF_HUB_OFFLINE`).
    - Gap: Extras `LlamaCppModelLoader` makes its own `GGUFSource` and takes no `offline` parameter. Thus LiveModelLoader cannot give the mode to the GGUF loader. Only a GGUF drafter that is not cached can still reach the Hub (the format lookup of HubModelLoader is offline, so an uncached GGUF model throws notCachedOffline before the GGUF loader). The doc comment of `offline` says this. New task ^2gjy4dk records the Extras request.
    - `GGUFRepoMetadata.init(localGGUF:)` reads only a local path; it now makes `GGUFSource(offline: true)`. No new API, because a model on the disk needs no Hub.
    - `offline: true` given in LiveModelLoaderCacheFolderTests (3 loaders), LiveModelLoaderCoreMLTests (3 loaders with a fake cache), ModelStorageSummaryTests (`ModelStorage`). TokenProvider tests and `publicInitMakesAHubModelLoader` only read the loader and send no request; not changed. RealModelSupport not changed.
    - No test expected a network failure: `noCacheFolderUsesTheDefaultCache` expects `MLXModelLoaderError.notInCache`, which comes from the cache-only weight measure; it still passes offline.
    - New test LiveModelLoaderOfflineTests: offline live loader throws `ModelDownloadError.notCachedOffline(repository:revision: "main")` for an uncached model. RED was the compile error "extra argument 'offline'", then GREEN.
  timestamp: 2026-11-16T14:55:45.719937+00:00
- actor: claude-code
  id: 01m7jdpvp9y67cn1hgd3bhnr2g
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderOfflineTests.swift (new), LiveModelLoaderCacheFolderTests.swift, LiveModelLoaderCoreMLTests.swift, ModelStorageSummaryTests.swift. `swift test --filter LiveModelLoader` 14 tests in 5 suites pass; `--filter ModelStorageSummary` 17 tests pass; full `swift test` one time: 2803 tests in 327 suites pass, exit 0, no warnings.
    - next: /review
  timestamp: 2026-11-16T14:55:48.425006+00:00
- actor: claude-code
  id: 01m7jds0w7ksj4e1bn5mkm2e73
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (e2455271); 0 findings (0 confirmed, 0 refuted); no prior findings
    - next: none. The task is in done.
  timestamp: 2026-11-16T14:56:59.271244+00:00
position_column: done
position_ordinal: ffffffffffa180
title: Unit tests with a fake hub cache use the offline mode of the hub source (Extras 2f64483)
---
## What
FoundationModelsExtras 2f64483 adds an offline mode to the hub source. Since Extras 164564e, each MLX or Core ML load first asks the Hugging Face Hub for the commit and the file list. Router unit tests with a fake hub cache (`FakeHubCache`) thus send a real request, get 401/404, and fall back to the cache. They pass, but they reach the network.

Each public init that makes a hub source has a new last parameter `offline: Bool? = nil`: `HubModelLoader(..., offline:)`, `GGUFSource(cacheDirectory:tokenProvider:offline:)`, `MLXModelLoader(..., offline:)`, `CoreMLModelLoader(..., offline:)`, `ModelStorage(cacheDirectory:tokenProvider:offline:)`. `nil` reads `HF_HUB_OFFLINE`. A test must give the parameter, not set the process environment. A `HubModelLoader` with its own GGUF loader needs `offline: true` on that `GGUFSource` too. In offline mode, a model that is not in the cache throws `ModelDownloadError.notCachedOffline(repository:revision:)`.

## Acceptance criteria
- [x] Extras in `.build` is at 2f64483 or later.
- [x] Each unit test that uses a fake hub cache, or a hub source over a temp cache, gives `offline: true`. When a test reaches the hub source through Router code (`LiveModelLoader`), Router gets a way to pass the mode (decide the API; the default keeps the current behavior).
- [x] The real-model support (`FoundationModelsRouterRealModelSupport`) does NOT turn on the offline mode.
- [x] A test that expected a network failure for a model that is not cached is changed to expect `notCachedOffline`, where this applies.
- [x] Full `swift test` is green with no new warnings.

## Files
Tests/FoundationModelsRouterTests/LiveModelLoader*.swift, ModelStorageSummaryTests.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift. #router-3