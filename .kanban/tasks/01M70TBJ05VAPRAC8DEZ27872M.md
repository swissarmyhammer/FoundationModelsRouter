---
assignees:
- claude-code
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: todo
position_ordinal: '8280'
title: 'GGUF: load llama.cpp at the context the router resolved'
---
## Problem
llama.cpp fixes the context (`n_ctx`) at load: `LlamaLanguageModel.Options.contextSize`, which defaults to 4096. The router resolves the context of a profile at resolve time (JointFit, `RoutedModel.contextTokens`). `ModelPoolKey` is only ref + role, and `LlamaCppModelLoader(options:)` fixes its options at init. Thus a GGUF model would load at 4096 whatever the profile resolved. MLX needs no context at load, which is why the pool never carried one.

## What
Pass the context that was resolved for each load through to `LlamaLanguageModel.Options.contextSize`. `LiveModelLoader.loadLLM(ref:slot:context:reporting:)` already receives `context`, and ignores it today. This needs an Extras change, for example a context in the pool key, or a per-load options hook on `LlamaCppModelLoader`. Agree the shape with the Extras session (foundationmodelsextras-1f).

Decide and record two things:
- Two profiles that resolve one GGUF ref at different contexts: share the load at the larger context, or load twice.
- `maxLiveSequences` × context is the KV memory llama.cpp allocates. Make the router's KV estimate for a GGUF model match it.

## Acceptance
- [ ] A GGUF model loads with `contextSize` == the resolved `contextTokens`, and a test proves it.
- [ ] The container's contextWindow reports that same value. #gguf