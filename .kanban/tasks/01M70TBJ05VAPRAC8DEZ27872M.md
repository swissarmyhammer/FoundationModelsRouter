---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m71169spwbnyw4w516bxtqt5
  text: 'Research: Extras resolved at eb0f0d7 (contains c1d8ddf + 098aeaa) in both Package.resolved (gitignored). Router sites building ModelPoolKey: LiveModelLoader.loadGeneration/loadEmbedding, SlotPoolLoader.acquireHold, Router.acquire (isResident lookup), Router.footprintBytes (residentKeys sizing). Key subtlety: the pool calls `loader.poolKey(for:)` at each acquire, and both SlotPoolLoader and LiveModelLoader currently use the Extras default (drops the context). So passing contextSize into the key alone is not enough: SlotPoolLoader must forward poolKey to the router ModelLoader, and LiveModelLoader must forward to its HubModelLoader (which keeps the context only for GGUF). Plan: add `poolKey(for:)` to the router `ModelLoader` protocol (default drops context, as Extras), forward in LiveModelLoader and SlotPoolLoader; SlotPoolLoader.load passes key.contextSize ?? context; residency lookups in Router use a rule that a resident key with no context serves every context and one with a context serves any context ≤ it.'
  timestamp: 2026-11-09T20:49:57.558074+00:00
- actor: claude-code
  id: 01m711nz26pam4b6ng2zw4j9ze
  text: 'Implementation landed. The router `ModelLoader` protocol gains `poolKey(for:)` (default drops the context, like Extras). `LiveModelLoader.poolKey` forwards to its model loader (HubModelLoader keeps the context only for GGUF); `loadLLM` asks the model loader for the key of ref at `context` and loads under it; the pool path `load(key:)` passes the key through unchanged. `SlotPoolLoader.poolKey` forwards to the router loader; `acquireHold` asks with `ModelSlot.poolKey(of:context:)` (generation slots carry the resolved context, embedding none); `load` passes `key.contextSize ?? context`. Router residency (`acquire` isResident, `footprintBytes` residentKeys) uses `ModelPoolKey.canServe(_:)`. Gotcha for the next agent: passing a context in the request key alone does nothing, because the Extras pool calls `loader.poolKey(for:)` first and the default drops it; both SlotPoolLoader and LiveModelLoader had to forward. Known limit: a GGUF model loaded into the shared pool by an outside caller with a nil context sits under a nil-context key; `canServe` treats that as serving any context, while the Extras pool would load a new copy. The router never requests a GGUF model with no context. Moved a test helper `SlotPoolLoader.acquireHold(of:in: ModelPool…)` in SlotPoolLoaderTests from fileprivate to internal so the new suites reuse it.'
  timestamp: 2026-11-09T20:58:30.854759+00:00
- actor: claude-code
  id: 01m711p2p27y0w38swt7ktz1we
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Resolution/{ModelLoader,LiveModelLoader,SlotPoolLoader,PoolPrimitives}.swift, Sources/FoundationModelsRouter/Core/ModelSlot.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/PoolKeyContextTests.swift (new, 16 tests), Tests/FoundationModelsRouterTests/LiveLLMContainerGGUFTests.swift (+2 tests), Tests/FoundationModelsRouterTests/SlotPoolLoaderTests.swift (helper access). `swift build --build-tests`: only the pre-existing mlx-swift_Cmlx.bundle missing-creator notice. `swift test`: 2468 + 38 + 19 = 2525 passed, 0 failed (was 2507). `swift build --build-tests --package-path IntegrationTests`: clean apart from the same notice. Extras resolved at eb0f0d7 (contains 098aeaa) in both packages.
    - next: /review
  timestamp: 2026-11-09T20:58:34.562372+00:00
- actor: claude-code
  id: 01m711y72z8e7391vghjpdbhfj
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1aacab39) — 0 findings (14 attempted, 0 confirmed, 1 refuted, 0 failed); 9 files reviewed, 8 .kanban files ignored
    - next: none — task moved to done
  timestamp: 2026-11-09T21:03:01.215364+00:00
- actor: claude-code
  id: 01m711yds29z4qhv3hwf37rmdg
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files (ModelLoader.poolKey, LiveModelLoader/SlotPoolLoader context keys, ModelPoolKey.canServe, 18 tests)
    - test: green — swift test 2525 passed, IntegrationTests builds
    - commit: 1aacab39
    - review: clean — 0 findings
  timestamp: 2026-11-09T21:03:08.066777+00:00
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: done
position_ordinal: fffffffff080
title: 'GGUF: load llama.cpp at the context the router resolved'
---
## Problem
llama.cpp fixes the context (`n_ctx`) at load: `LlamaLanguageModel.Options.contextSize`, which defaults to 4096. The router resolves the context of a profile at resolve time (JointFit, `RoutedModel.contextTokens`). `ModelPoolKey` is only ref + role, and `LlamaCppModelLoader(options:)` fixes its options at init. Thus a GGUF model would load at 4096 whatever the profile resolved. MLX needs no context at load, which is why the pool never carried one.

## What
Pass the context that was resolved for each load through to `LlamaLanguageModel.Options.contextSize`. `LiveModelLoader.loadLLM(ref:slot:context:reporting:)` already receives `context`, and ignores it today. This needs an Extras change, for example a context in the pool key, or a per-load options hook on `LlamaCppModelLoader`. Agree the shape with the Extras session (foundationmodelsextras-1f). (Landed in Extras c1d8ddf: `ModelPoolKey(ref:role:contextSize:)` and `PooledModelLoader.poolKey(for:)`.)

Decide and record two things:
- Two profiles that resolve one GGUF ref at different contexts: share the load at the larger context, or load twice.
- The KV memory llama.cpp allocates for a GGUF model, and how the router's KV estimate for a GGUF model matches it. (The task first said "`maxLiveSequences` × context"; that is wrong, see Decisions.)

## Decisions
- **Two contexts for one GGUF ref: Extras' rule applies.** The pool reuses the smallest resident load of the same ref + role whose context is ≥ the one requested; otherwise it loads a new copy, and never reloads in place. The container window then reports the context the model actually loaded at (`LlamaLanguageModel.contextSize`), which can be larger than the router resolved. The router keeps budgeting with its resolved `contextTokens`. The router's residency checks (`Router.acquire`, `Router.footprintBytes`) follow the same rule through `ModelPoolKey.canServe(_:)`: a resident key with no context (MLX, Core ML) serves every context; a resident key with a context serves a request at that context or smaller.
- **KV memory.** Per FoundationModelsLlamaCpp (GGUFHeader, a082eff), llama.cpp's unified KV cache is `n_ctx` cells shared by all sequences, so the KV term does NOT scale with `maxLiveSequences`; only the recurrent state does. The router's pre-download KV estimate for GGUF is task ^7k8wtq6, not this task.

## Acceptance
- [x] A GGUF model loads with `contextSize` == the resolved `contextTokens`, and a test proves it.
- [x] The container's contextWindow reports that same value. #gguf