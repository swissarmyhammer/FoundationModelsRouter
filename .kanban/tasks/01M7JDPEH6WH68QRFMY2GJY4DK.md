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
position_column: todo
position_ordinal: '80'
title: Extras LlamaCppModelLoader takes the offline mode, and LiveModelLoader gives it
---
## What
Extras 2f64483 gives `offline: Bool? = nil` to `GGUFSource`, but `LlamaCppModelLoader(cacheDirectory:tokenProvider:options:)` makes its own `GGUFSource` and takes no `offline` parameter. Thus `LiveModelLoader(offline: true)` cannot give the mode to its GGUF loader. A GGUF drafter that the cache does not hold is downloaded unless `HF_HUB_OFFLINE` is set. (The format lookup of `HubModelLoader` is offline, thus an uncached GGUF model itself throws `notCachedOffline` before the GGUF loader.)

## Acceptance criteria
- [ ] Ask the FoundationModelsExtras session for `offline: Bool? = nil` as the last parameter of `LlamaCppModelLoader.init`, given to its `GGUFSource`.
- [ ] After that Extras commit, `LiveModelLoader.init` gives its `offline` value to `LlamaCppModelLoader` too, and the doc comment of `offline` drops the GGUF drafter note.
- [ ] A unit test proves that an offline live loader throws `ModelDownloadError.notCachedOffline` for a GGUF model whose drafter the cache does not hold.

## Files
Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderOfflineTests.swift. Found in ^688b96g. #router-3