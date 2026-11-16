---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jdw2g1j77n9e67axny7jtc
  text: |-
    ### blocked — waiting for Extras push
    - Extras committed 2feae8f (NOT on origin/main yet; it waits for the CI run of 2f64483). The Extras session tells us when it is pushed.
    - API: `LlamaCppModelLoader(cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment, options: LlamaLanguageModel.Options = .init(), offline: Bool? = nil)`. It gives `offline` to its `GGUFSource`. `true` sends no Hub request; a GGUF model that is not cached throws `ModelDownloadError.notCachedOffline(repository:revision:)`. `nil` reads `HF_HUB_OFFLINE`.
    - next: when 2feae8f is on origin/main, update Extras in .build and give `LiveModelLoader.offline` to the `LlamaCppModelLoader`.
  timestamp: 2026-11-16T14:58:39.233816+00:00
- actor: claude-code
  id: 01m7jpp0qmdy6y92kmrbb5eq7s
  text: |-
    ### research
    - Extras updated in .build: Package.resolved (gitignored) now names 8c312a8. Package.swift tracks `branch: "main"`, thus no pin change.
    - `LlamaCppModelLoader.load(key:progressHandler:)` gets the drafter files first with `source.files(of: drafter)`. With `offline: true`, a drafter that the cache does not hold throws `ModelDownloadError.notCachedOffline(repository:revision:)` before the model files.
    - Before the change, the GGUF source gets `nil` and reads `HF_HUB_OFFLINE`. In the test process that is not set, thus the drafter lookup sends a Hub request, and `HubRequestGuard` records an issue.
    - The `offline: false` path can show RED only when the test run sets `HF_HUB_OFFLINE=1` (then the old `nil` reads true). The `nil` path has no test that can fail: before and after the change it reads `HF_HUB_OFFLINE`.
    - The other GGUF fake-cache test (`LiveModelLoaderCacheFolderTests.cacheFolderHoldsTheGGUFFiles`) already gives `offline: true` to `LiveModelLoader`.
  timestamp: 2026-11-16T17:32:38.004536+00:00
- actor: claude-code
  id: 01m7jqcbdgp5rj9p2y7ehccx4q
  text: |-
    ### implementation
    - Extras in .build updated to 8c312a8 (Package.resolved is gitignored; Package.swift tracks branch main, no change).
    - `LiveModelLoader.init` gives `offline` to `LlamaCppModelLoader(..., offline:)`. The doc comment of `offline` now says that the `HubModelLoader` and its `LlamaCppModelLoader` get the same value.
    - New tests in LiveModelLoaderOfflineTests: (1) an offline loader throws `notCachedOffline` for the drafter of a GGUF model in a fake cache that holds only the model. RED before the change: HubRequestGuard caught a request to `huggingface.co/api/models/router-tests/offline-gguf-drafter/tree/main` and the error was NSURLError -1009. (2) `LiveModelLoader(offline: false)` gives `false` to the GGUF hub source. RED only with `HF_HUB_OFFLINE=1` on the run (the old `nil` read the variable); I saw it fail with the code line reverted.
    - No `nil` test: before and after the change, `nil` reads `HF_HUB_OFFLINE`, thus no test can fail on it.
    - New test helper `requireGGUFHubSource()` in LiveModelLoaderHubModelLoader.swift; `requireGGUFHubClient()` uses it.
    - The only other GGUF fake-cache test (`cacheFolderHoldsTheGGUFFiles`) already gives `offline: true`.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderOfflineTests.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderHubModelLoader.swift. `swift test --filter LiveModelLoaderOfflineTests`: 3 passed. Full `swift test`: 2839 tests in 330 suites passed, plus 48 and 19 in the other test bundles; 0 failures. One SwiftPM build warning that is not in this change: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle.
    - next: /review
  timestamp: 2026-11-16T17:44:49.840447+00:00
- actor: claude-code
  id: 01m7jqgp63mjjp5jtsp5xwtrz9
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (35b3ce8b). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. The review engine examined 3 files. The .reviewignore file excluded 2 .kanban files.
    - next: None. The task is in done.
  timestamp: 2026-11-16T17:47:11.939861+00:00
position_column: done
position_ordinal: ffffffffffa680
title: Extras LlamaCppModelLoader takes the offline mode, and LiveModelLoader gives it
---
## What
Extras 2f64483 gives `offline: Bool? = nil` to `GGUFSource`, but `LlamaCppModelLoader(cacheDirectory:tokenProvider:options:)` makes its own `GGUFSource` and takes no `offline` parameter. Thus `LiveModelLoader(offline: true)` cannot give the mode to its GGUF loader. A GGUF drafter that the cache does not hold is downloaded unless `HF_HUB_OFFLINE` is set. (The format lookup of `HubModelLoader` is offline, thus an uncached GGUF model itself throws `notCachedOffline` before the GGUF loader.)

## Acceptance criteria
- [x] Ask the FoundationModelsExtras session for `offline: Bool? = nil` as the last parameter of `LlamaCppModelLoader.init`, given to its `GGUFSource`. (Extras 2feae8f, on origin/main with 8c312a8.)
- [x] After that Extras commit, `LiveModelLoader.init` gives its `offline` value to `LlamaCppModelLoader` too, and the doc comment of `offline` drops the GGUF drafter note.
- [x] A unit test proves that an offline live loader throws `ModelDownloadError.notCachedOffline` for a GGUF model whose drafter the cache does not hold.

## Files
Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderOfflineTests.swift. Found in ^688b96g. #router-3