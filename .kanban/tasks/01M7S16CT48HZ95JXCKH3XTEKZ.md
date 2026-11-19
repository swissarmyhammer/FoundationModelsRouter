---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'A GGUF fork keeps the cache of its source: the FoundationModelsLlamaCpp pin and tests (D205 (f), part 3)'
---
## Goal

The GGUF part of the fork cache copy. Brief: `../.briefs/fork-kv/router-brief.md` (items 5, 6); overview `overview.md`.

## Depends on

FoundationModelsLlamaCpp on `main`: the copy of the sequence on a partial live hit (the source record stays live). Today `main` is pinned at `2a6b9d8`. Do not start before the FoundationModelsLlamaCpp session sends the sha. Then update the pin with `--manifest-cache local`.

## Change

- The Router calls no copy for a GGUF slot. The cache of FoundationModelsLlamaCpp copies the sequence on a partial live hit.
- Make sure that the copy of part 1 is not called for a GGUF slot (or that it is a no-op there).
- The fit does not change: the copy is a live sequence of the same context, inside the KV of the context and inside the `defaultMaxLiveSequences` recurrent estimate (`Sizing/GGUFCacheSizing.swift`). Check that the doc of part 1 says this.

## Tests

- [ ] A GGUF fork reuses the shared prefix (its first call reports cached input tokens).
- [ ] The next turn of the source is a full hit with no prefill of its history.

## After

Push when green. Send the sha to testudoapp-9a. #d205