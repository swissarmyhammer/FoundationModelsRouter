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
- actor: claude-code
  id: 01m7sgd4k8wbmq7y6f3e735qfb
  text: |-
    Research:
    - The root Package.resolved already pins FoundationModelsLlamaCpp at c11b800. IntegrationTests/Package.resolved (gitignored) was at 2a6b9d8; updated to c11b800 with `swift package --package-path IntegrationTests --manifest-cache local update FoundationModelsLlamaCpp`.
    - A GGUF slot runs MLXFoundationModelsSessionBackend over a LlamaLanguageModel (a struct). LlamaLanguageModel does not conform to SessionPromptCacheCopying, so MLXFoundationModelsSessionBackend.copyPromptCache gives nil, and RoutedSessionActor.takePromptCacheCopy returns before the log and before the budget send. No copy reaches the GGUF model and no budget goes out. No production change is necessary for this.
    - The doc of PromptCacheBudget already says the GGUF copy is a live sequence inside the KV of the context and inside the defaultMaxLiveSequences recurrent estimate. It does not say that makeRoom counts the shared cells one time, and GGUFCacheSizing says nothing about the copy. Both docs get that text.
    - Plan: unit test in LiveLLMContainerGGUFTests (the backend of a GGUF container gives no copy outcome); integration suite GGUFForkPromptCacheIntegrationTests on Qwen2.5-1.5B-Instruct GGUF (attention only, no reasoning, in the local HF cache).
  timestamp: 2026-11-19T08:57:36.616203+00:00
- actor: claude-code
  id: 01m7sgt82ys63s8xx8pb3m4ezw
  text: |-
    ### implement — changed
    - evidence:
      - No production code change. A GGUF slot runs MLXFoundationModelsSessionBackend over LlamaLanguageModel, which does not conform to SessionPromptCacheCopying. Thus backend.copyPromptCache gives nil, and takePromptCacheCopy logs nothing and sends no budget.
      - Docs: PromptCacheBudget ("The copy of a fork", GGUF bullet: the router calls no copy; llama_memory_seq_cp into a free sequence; inside the KV of the context and the defaultMaxLiveSequences recurrent estimate; makeRoom counts the shared cells one time), GGUFCacheSizing (the same facts), SessionPromptCacheCopying, RoutedSessionActor.takePromptCacheCopy.
      - Unit: LiveLLMContainerGGUFTests.backendOfAGGUFContainerCopiesNoPromptCache. RED with a temporary conformance of LlamaLanguageModel to SessionPromptCacheCopying (1 issue), GREEN after its removal: `swift test --filter FoundationModelsRouterTests.LiveLLMContainerGGUFTests` 11 tests in 1 suite passed.
      - Integration: new GGUFForkPromptCacheIntegrationTests (Qwen/Qwen2.5-1.5B-Instruct-GGUF q4_k_m, attention only, no reasoning): fork at .lastCompletedTurn and at .historyPosition; the first call of the fork reuses at least the history less 16 seam tokens and answers the code word; the next turn of the source reuses its whole history less 16. Each test has its own code word, so a record of an earlier test cannot satisfy the bounds. Run alone once: 2 tests in 1 suite passed (14.5 s). IntegrationTests pin updated to c11b800 (Package.resolved is gitignored there).
      - Shared helpers moved to Support/ForkPromptCacheCopySupport.swift (MeasuredAnswer.templateSeamTokens, reuseBound(of:), cachedTokensOfFirstCall(), historyTokens(), RouterSessionDirectory.liveFork(of:at:clientID:), RoutedSession.positionOfSecondPrompt()); ForkPromptCacheCopyIntegrationTests uses them. It builds; it was not run in this step (only the new suite was run).
      - Full `swift test` once: 3104 tests in 353 suites passed, plus 50 and 19; 0 failures; only the known mlx-swift_Cmlx.bundle "missing creator" warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-suite.txt
    - next: /review. Not committed; task stays in doing.
  timestamp: 2026-11-19T09:04:46.174775+00:00
position_column: doing
position_ordinal: '80'
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

- [x] A GGUF fork reuses the shared prefix (its first call reports cached input tokens).
- [x] The next turn of the source is a full hit with no prefill of its history.

## After

Push when green. Send the sha to testudoapp-9a. #d205