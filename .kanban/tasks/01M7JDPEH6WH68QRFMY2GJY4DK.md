---
assignees:
- claude-code
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