---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m70xjjvhnwj4yjhg9pxn0qtj
  text: |-
    Implemented (uncommitted):
    - `MLXFoundationModelsContainer` → `LiveLLMContainer`, which holds `any LanguageModel`. The executor configuration compares the wrapped model's configuration as `any Hashable & Sendable`.
    - `LiveLLMContainer.make(wrappingLoaded:ref:)` dispatches MLX vs llama and returns nil for other types. The name is deliberately distinct from `make(wrapping:)`: an overload with the same name resolved to itself inside the switch (infinite async recursion → jetsam SIGKILL).
    - The llama container: window = `LlamaLanguageModel.contextSize`, token counter = new `LlamaTokenCounter` over `LlamaTokenizer` (FoundationModelsLlamaCpp a082eff).
    - `LiveModelLoaderError.notAnMLXLanguageModel` → `unsupportedGenerationModel`.
    - `LiveLLMContainer.mlxModel` lets the integration tests evict and inspect the MLX model.
    - 4 hermetic tests over the vocab-only qwen35 fixture (LiveLLMContainerGGUFTests). Root suite: 2449 pass. The IntegrationTests package builds.

    MLX-only for now (llama has no equivalent yet): `ReasoningSwitchable` (reasoning off for one call is skipped, which the backend already handles for a model that can't switch), `SessionPromptCacheScoping`/`Releasing` (llama manages its own cache tiers). The speculative-decoding metadata keys match, so `GenerationCallUsage.speculativeDecoding` reads llama responses unchanged; the real-model test will verify it.
  timestamp: 2026-11-09T19:46:45.745358+00:00
- actor: claude-code
  id: 01m70zhg83f8x76s4kw6g3fbrm
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 3 engine findings this pass (3 confirmed, 5 refuted) plus 2 prior-pass findings carried in; 5 open items: RecordedTranscriptCompactionIntegrationTests.swift:287, Qwen38ToolAnswerIntegrationTests.swift:230, SessionTreeRestorationIntegrationTests.swift:325, LiveModelLoader.swift:87, LiveModelLoaderHubModelLoader.swift:81
    - next: implement the Review Findings (2026-11-09 14:16) checklist, then re-review
  timestamp: 2026-11-09T20:21:07.459450+00:00
- actor: claude-code
  id: 01m70zj1zq0tg4261mvc04bhhq
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — LiveLLMContainer, LlamaTokenCounter, error rename, test edits
    - test: green — swift test, 2449 passed; IntegrationTests builds
    - commit: 662a44b5
    - review: findings — RecordedTranscriptCompactionIntegrationTests.swift:287, Qwen38ToolAnswerIntegrationTests.swift:230, SessionTreeRestorationIntegrationTests.swift:325, LiveModelLoader.swift:87, LiveModelLoaderHubModelLoader.swift:81
  timestamp: 2026-11-09T20:21:25.623134+00:00
- actor: claude-code
  id: 01m70zs793z9e2q90gp4g514v7
  text: |-
    Fixed all 5 Review Findings (2026-11-09 14:16):
    - RecordedTranscriptCompaction: the eviction is now `defer { await loaded.evict() }` right after the load. The inline success-path evict is gone. The assertions read only `outcome` and the token counter, so an early evict isn't needed.
    - New `package func evict() async` on `RealModelContainer` (Tests/FoundationModelsRouterRealModelSupport), marked `periphery:ignore` like `load`. It forwards to `container.mlxModel?.evict()`. All 42 sites in IntegrationTests/Tests that evicted a RealModelContainer's model now call it, across 17 files including Support/Qwen38ResidentModel.
    - Not changed: 5 `mlxModel?.evict()` sites whose receiver is a bare `LiveLLMContainer`, not a RealModelContainer. These are `ChokepointHarness.container` (LanguageModelSessionBackendTests, 3 sites), `Harness.container` (TranscriptReconstruction, 1) and `UncontaminatedLoad.container` (PropagationProbe, 1). They fall outside the RealModelContainer scope the dispatcher gave. To route them through the helper, those structs would have to hold the RealModelContainer.
    - Removed `LiveLLMContainer.init`. The synthesized memberwise init is internal too and has the same labels and order. The 3 callers (LiveLLMContainerPooling ×2, UnloadableMLXModel) compile unchanged.
    - Removed `storedLoader(named:in:)`. The 3 `require*ModelLoader` helpers call `stored(named:in:)` directly.
  timestamp: 2026-11-09T20:25:20.419627+00:00
- actor: claude-code
  id: 01m70zsab5sqjbr010dq4nwegn
  text: |-
    ### implement — changed
    - evidence: 21 files. Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderHubModelLoader.swift, and 18 IntegrationTests/Tests files (17 eviction call-site files plus Support/Qwen38ResidentModel). `swift build --build-tests` passed. `swift test` passed 2449 tests in 289 suites, plus 38 and 19. `swift build --build-tests --package-path IntegrationTests` passed. The only warning is SwiftPM's build-graph "missing creator for mutated node" on the mlx-swift_Cmlx.bundle, with no compiler warnings.
    - next: /review
  timestamp: 2026-11-09T20:25:23.557313+00:00
- actor: claude-code
  id: 01m70zsgyqqmbj7t55bmvjnpe4
  text: 'Correction to the two comments above. The diff touches 20 files: 3 outside IntegrationTests and 17 IntegrationTests/Tests files, Support/Qwen38ResidentModel.swift among them. The earlier comments said 21 and 18. The eviction sites moved to `RealModelContainer.evict()` number 40, not 42.'
  timestamp: 2026-11-09T20:25:30.327634+00:00
- actor: claude-code
  id: 01m7107xeycxpdafa2v6t5v7c2
  text: |-
    ### finish iteration 2 — commit (review pending)
    - implement: changed — 20 files (5 findings fixed)
    - test: green — swift test 2449/38/19 passed, 0 failures; IntegrationTests builds. The only warning is the SwiftPM "missing creator for mutated node … mlx-swift_Cmlx.bundle"; it also appears on 662a44b5~1 (before GGUF, no .Cxx), so it comes from the dependency and isn't new
    - commit: 453d78d9
  timestamp: 2026-11-09T20:33:21.886659+00:00
- actor: claude-code
  id: 01m710g3f5newaxftxbq2rbfwd
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (453d78d9) — 0 findings, the 5 prior items are resolved; review file LiveLLMContainerPooling.swift — 0 findings; review file LlamaTokenCounter.swift — 1 finding: Sources/FoundationModelsRouter/Resolution/LlamaTokenCounter.swift:12 (reuse/reuse)
    - next: implement the LlamaTokenCounter reuse finding (reuse or generalize TokenizerTokenCounter), then re-review
  timestamp: 2026-11-09T20:37:50.181577+00:00
- actor: claude-code
  id: 01m710gkkzbg8vg226whyegqxn
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 20 files
    - test: green — swift test 2449 passed (the SwiftPM Cmlx.bundle notice was already there before this work)
    - commit: 453d78d9
    - review: findings — LlamaTokenCounter.swift:12 (reuse/reuse); all 5 earlier items fixed
  timestamp: 2026-11-09T20:38:06.719913+00:00
- actor: claude-code
  id: 01m710txch0nt48sd5qnhjmth5
  text: |-
    Fixed the LlamaTokenCounter reuse finding (uncommitted):
    - New internal protocol `CountingTokenizer: Sendable` in TokenizerTokenCounter.swift: `plainTextTokens(of:) -> [Int]`, `leadingText(of:tokens:limit:)` (called only for a cut, 0 < limit < tokens.count), `renderedTokenCount(of:) throws`.
    - `TokenizerTokenCounter` now holds `any CountingTokenizer` and keeps the shared rules: count(text), count(transcript), and prefix returns "" for limit <= 0 and the text unchanged when it fits. `init(tokenizer: any Tokenizer)` stays as a convenience that wraps the MLX tokenizer, so the existing tests and CompactionPartCostTests compile unchanged.
    - `MLXCountingTokenizer` wraps the MLX `Tokenizer`. The chat-template render, including the `TokenizerError.missingChatTemplate` plain-text fallback, moved into it unchanged.
    - `LlamaTokenizer` conforms through an extension. Its own `renderedTokenCount(of:)` satisfies the requirement. `plainTextTokens` maps the Int32.max throw to no tokens. `leadingText` uses the tokenizer's own `prefix(of:tokens:)`, so a cut never falls inside a character. Rejected alternative: decoding the token prefix with `text(of:)` would end in U+FFFD when the cut splits a character. Cost: the cut re-tokenizes the text one time.
    - Deleted LlamaTokenCounter.swift. `LiveLLMContainer.make(wrapping: LlamaLanguageModel, ref:)` now builds `TokenizerTokenCounter(tokenizer: try model.tokenizer())`.
    - One edge differs from the old type: for a text over Int32.max bytes, which counts as 0 tokens, prefix now returns the text unchanged. The old type returned "".
    - New test in LiveLLMContainerGGUFTests: the shared counter over a LlamaTokenizer cuts a multi-byte text exactly as `LlamaTokenizer.prefix` cuts it. It failed to compile first (RED), then passed.
  timestamp: 2026-11-09T20:43:44.401898+00:00
- actor: claude-code
  id: 01m710v06jr77q7kwd1pyyrsq3
  text: |-
    ### implement — changed
    - evidence: 4 files. Sources/FoundationModelsRouter/Resolution/TokenizerTokenCounter.swift, Sources/FoundationModelsRouter/Resolution/LiveLLMContainerPooling.swift, Sources/FoundationModelsRouter/Resolution/LlamaTokenCounter.swift (deleted), Tests/FoundationModelsRouterTests/LiveLLMContainerGGUFTests.swift. `swift build --build-tests` built with no compiler warnings. The only notice is the SwiftPM "missing creator … mlx-swift_Cmlx.bundle", which was already there. `swift test` passed 2450 tests in 289 suites, plus 38 and 19. `swift build --build-tests --package-path IntegrationTests` completed.
    - next: /review
  timestamp: 2026-11-09T20:43:47.282973+00:00
- actor: claude-code
  id: 01m710zemdzadhzbd7jjjbr72f
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a257721b): 0 findings, 0 confirmed, 0 refuted; 4 files reviewed. All prior Review Findings items checked. Tool-rule declines only concern the deleted Sources/FoundationModelsRouter/Resolution/LlamaTokenCounter.swift.
    - next: task moved to done
  timestamp: 2026-11-09T20:46:13.133660+00:00
- actor: claude-code
  id: 01m7110178cp10qncsev1zg0fq
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — TokenizerTokenCounter generic over CountingTokenizer, LlamaTokenCounter deleted
    - test: green — swift test 2507 passed, IntegrationTests builds
    - commit: a257721b
    - review: clean — 0 findings, 6/6 prior items checked
  timestamp: 2026-11-09T20:46:32.168995+00:00
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: done
position_ordinal: ffffffffef80
title: 'GGUF: a generation container over LlamaLanguageModel'
---
## What
`LiveModelLoader.loadGeneration` accepts only an `MLXLanguageModel`. Anything else throws `LiveModelLoaderError.notAnMLXLanguageModel` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift ~1140). Make it accept a `LlamaLanguageModel` too.

`MLXFoundationModelsSessionBackend` already holds `any FoundationModels.LanguageModel`. Only `MLXFoundationModelsContainer` (`let model: MLXLanguageModel`) and its `make(wrapping:ref:)` are tied to MLX, because they read the context window from config.json and the token counter from the MLX tokenizer. Generalize the container over the model (or add a llama container next to it):
- contextWindow: the context the model was loaded with (`LlamaLanguageModel.Options.contextSize`). See the context-at-load task.
- tokenCounter: over `LlamaLanguageModel.tokenCount(for:)`.
- Replace `notAnMLXLanguageModel` with an error that names both supported types.
- Check each MLX-only feature of the backend against llama, keep the ones it supports, and leave a note for the others: `ReasoningSwitchable` (reasoning off for one call), `SessionPromptCacheScoping`/`SessionPromptCacheReleasing`, `GenerationPassReporting`, eviction through the model loader, and the `SpeculativeDecodingOutcome` read (llama emits the same 4 metadata keys, so `GenerationCallUsage.speculativeDecoding` should fill unchanged).

## Acceptance
- [ ] A hermetic test: the loader wraps a LlamaLanguageModel built over a vocab-only GGUF from LlamaCppTestFixtures, and a session can be made.
- [ ] No MLX-only cast remains on the generation path, apart from the features marked as MLX-only. #gguf

## Review Findings (2026-11-09 14:16)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 40 file(s) reviewed, 12 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

> ⚠️ tool rules 'code-hygiene/disallowed-constructs-swift', 'code-hygiene/function-length-swift', 'code-hygiene/idioms-swift', 'code-hygiene/magic-numbers-swift' and 'code-hygiene/missing-docs-swift' each declined an item: they found no file at Sources/FoundationModelsRouter/Resolution/MLXFoundationModelsContainerPooling.swift (renamed to LiveLLMContainerPooling.swift in this change), so that path is unread.

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordedTranscriptCompactionIntegrationTests.swift:287` `completeness/invariant-propagation` — The eviction of the loaded model is placed on the success path only. If `TranscriptCompaction.run` (line 281) throws, the 14 GB of weights are never evicted. The sibling gated tests in this same change put the eviction in a `defer` (Qwen38ToolAnswerIntegrationTests.swift:200, SessionTreeRestorationIntegrationTests.swift:269 and :325, SummarizerPromptCacheIntegrationTests.swift:159), so a failing run here leaves the model resident and slows the suites that follow, which is the cost the comment at Qwen38ToolAnswerIntegrationTests.swift:222-229 describes. Move the eviction to a `defer` directly after `RealModelContainer.load` (line 273), as the sibling tests do, and keep the explicit evict on line 287 only if the early eviction before the assertions is still wanted. The `defer` covers both paths. (The prior pass confirmed the same defect at this line under `completeness/public-output-contract`: the eviction is inline, not in a defer.)
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Qwen38ToolAnswerIntegrationTests.swift:230` `reuse/reuse` — The `mlxModel?.evict()` teardown is duplicated across the gated integration suites. Use a shared `RealModelContainer` eviction helper. (Confirmed by the prior pass over this range.)
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift:325` `reuse/reuse` — The eviction teardown is duplicated. Use the shared `RealModelContainer` eviction helper. (Confirmed by the prior pass over this range.)
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:87` `code-hygiene/idioms-swift` — UseSynthesizedInitializer: remove this explicit initializer, which is identical to the compiler-synthesized initializer.
- [x] `Tests/FoundationModelsRouterTests/LiveModelLoaderHubModelLoader.swift:81` `reuse/reuse` — storedLoader(named:in:) is now a one-line forwarder to the generic stored(named:in:) added directly below it. It adds a second helper with the same behaviour under a different name, so there are two ways to read a stored property where one is enough. Drop storedLoader and call stored(named:in:) directly from requireMLXModelLoader, requireCoreMLModelLoader and requireGGUFModelLoader, or keep storedLoader as the only helper if its name is the clearer one. Keep one of the two.

## Review Findings (2026-11-09 14:33)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 20 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

## Review Findings (2026-11-09 14:35)

> Scope: `review file Sources/FoundationModelsRouter/Resolution/LiveLLMContainerPooling.swift` — reviewed the whole of each named file. 1 file(s) reviewed, 0 not reviewed.

## Review Findings (2026-11-09 14:36)

> Scope: `review file Sources/FoundationModelsRouter/Resolution/LlamaTokenCounter.swift` — reviewed the whole of each named file. 1 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsRouter/Resolution/LlamaTokenCounter.swift:12` `reuse/reuse` — The `LlamaTokenCounter` struct duplicates `TokenizerTokenCounter`: it wraps a tokenizer and implements the same `TokenCounter` count, transcript count, and prefix operations. Adding a second counter type for the same job splits the token-counting behavior across two types. Check whether `TokenizerTokenCounter` can take the `LlamaTokenizer` directly, through a protocol or a generic parameter, so the Llama path reuses it. If it cannot, generalize `TokenizerTokenCounter` over its tokenizer type and use it here, rather than keeping a parallel counter.