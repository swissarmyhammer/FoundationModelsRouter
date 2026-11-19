---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s3rf571anz73fm84772msb
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — not started. FoundationModelsLlamaCpp origin/main is at 2a6b9d8, with no copy of the sequence on a partial live hit (checked 2026-11-18).
    - next: start again when the FoundationModelsLlamaCpp session sends the sha; then update the pin with `--manifest-cache local`.
  timestamp: 2026-11-19T05:16:36.391751+00:00
- actor: claude-code
  id: 01m7sfvz19reyvjqw8pr6yvpxk
  text: |-
    Unblocked: FoundationModelsLlamaCpp D205 (f) is on main at c11b800 (foundationmodelsllamacpp-44, 2026-11-19). No public API change; the Router calls nothing.
    - A prompt that leaves a live record before the end of its last user message (a fork, or an edit of a user message) gets a copy of the live sequence (llama_memory_seq_cp) in a free sequence; the source record stays live. Spans and cache.lookups show cache.tier = "live_copy".
    - A prompt that holds the record to the end of its last user message is the next turn of the same session and takes the record. For /btw (full source transcript + a question) the fork takes the record, and the source's next turn gets a "live_copy" hit for the whole shared history. In both orders, neither side prefills the shared history again.
    - With no free sequence (maxLiveSequences = 1), the request takes and cuts the record as before.
    - makeRoom counts the KV cells that a copy shares one time.
    - A copy decodes with no draft until its sequence is empty: speculativeDecodingFallbackReason = "draftOutOfSync" in the fork's response metadata.
    - Known, not from this change: a full parallel integration run of FoundationModelsLlamaCpp can stop with "the registry lost the key of a model that it loaded" (ModelRegistry.swift:402); their board tracks it.
    Start after ^jx6ng3r ends (do not change the pin while another build runs in this tree). Update the pin with `swift package --manifest-cache local update FoundationModelsLlamaCpp`.
  timestamp: 2026-11-19T08:48:13.865352+00:00
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