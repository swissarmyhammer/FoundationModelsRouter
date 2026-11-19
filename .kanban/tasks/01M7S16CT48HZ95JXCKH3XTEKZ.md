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
- actor: claude-code
  id: 01m7sh2n8hvz2gbfzkzsw15raw
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`: engine counts findings 3, confirmed 3, refuted 3. The driver checks added 1 finding. Total 4 findings: GGUFForkPromptCacheIntegrationTests.swift:160, GGUFForkPromptCacheIntegrationTests.swift:181, GGUFForkPromptCacheIntegrationTests.swift:198, LiveLLMContainerGGUFTests.swift:150.
    - Driver checks:
      - A GGUF slot cannot reach a copy: LiveLLMContainer.copyPromptCache casts the model to SessionPromptCacheCopying, and only MLXLanguageModel conforms. backendOfAGGUFContainerCopiesNoPromptCache fails with a conformance. Correct.
      - Fail check: with no prefix reuse, the first call of the fork caches 0 and both tests fail. With 2a6b9d8, the history-position test fails (the fork takes and cuts the source record to the first turn, so the source reuses only the first turn). The last-completed-turn test does not fail with 2a6b9d8 (finding at :198).
      - Code words: BRAVO-4 and CHARLIE-9 are different, and each test makes its own isolated pool. A record of the earlier test shares only the instructions and "My code word is" with the later test. Correct.
      - Docs (PromptCacheBudget, GGUFCacheSizing, SessionPromptCacheCopying, takePromptCacheCopy, suite doc) agree with the FoundationModelsLlamaCpp rules in the task comments: copy with llama_memory_seq_cp into a free sequence, the source record stays live, a prompt to the end of its last user message takes the record, makeRoom counts shared cells one time.
    - next: implement the 4 open findings; task stays in review.
  timestamp: 2026-11-19T09:09:21.809738+00:00
- actor: claude-code
  id: 01m7sh3dc4n0sm6pfjx3vk42fm
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — PromptCacheBudget.swift, GGUFCacheSizing.swift, SessionPromptCache.swift, RoutedSessionActorPromptCache.swift (docs only); LiveLLMContainerGGUFTests (+1 unit test); GGUFForkPromptCacheIntegrationTests (new, 2); shared integration support
    - test: green — one full swift test run, 3104 tests in 353 suites (+50, +19), 0 failures; GGUFForkPromptCacheIntegrationTests 2/2 alone; ForkPromptCacheCopyIntegrationTests 11/11 (orchestrator run after the helper move)
    - commit: d3ce7d34
    - review: findings — GGUFForkPromptCacheIntegrationTests.swift:160, :181 (copied helpers), :198 (the last-completed-turn test passes with the old llama.cpp 2a6b9d8), LiveLLMContainerGGUFTests.swift:150 (copied backend setup)
  timestamp: 2026-11-19T09:09:46.500572+00:00
- actor: claude-code
  id: 01m7shfrp6paedv50tj1b7jn18
  text: |-
    ### implement — changed
    - evidence:
      - Findings 1 and 2: Support/ForkPromptCacheCopySupport.swift now has `AnsweredSource` (session: RoutedSessionActor, first, second) with `answering(_:then:on:maxTokens:)`, and the free function `closeEach(_:)`. Both fork suites use them; their private `AnsweredSource` and `close(_:)` copies are deleted. The GGUF suite gives its prompts (with its own code word) as parameters.
      - Finding 3: the last-completed-turn GGUF test now also answers `forkFollowUpPrompt` on the fork after the next turn of the source, and expects its first call to reuse `reuseBound(of: forkAnswer.historyTokens())`. `forkPrompt` is longer and starts with a word that is not the first word of `sourceFollowUpPrompt`, so the history of the fork is more than `templateSeamTokens` longer than the history that it shares with the source. Doc comments of the test and of the suite now name the production change (a next turn of the source that takes and cuts the record of the fork, as before c11b800).
      - Old-pin proof: IntegrationTests/Package.resolved set to FoundationModelsLlamaCpp 2a6b9d8 (`swift package --manifest-cache local resolve`), `swift build --build-tests` OK, the one test alone: 1 issue, only `forkFollowUp.cachedTokensOfFirstCall() >= forkBound` failed (the other three expectations passed). Pin set back to c11b800 (resolve, checkout at c11b800), build OK.
      - Finding 4: LiveLLMContainerGGUFTests has `private static func makeBackend(of:)`; both backend tests use it.
      - Unit: `swift test --filter FoundationModelsRouterTests.LiveLLMContainerGGUFTests` 11 tests in 1 suite passed.
      - Integration (c11b800): GGUFForkPromptCacheIntegrationTests alone 2 tests passed; ForkPromptCacheCopyIntegrationTests alone 11 tests passed.
      - Full `swift test` once: 3104 tests in 353 suites passed, plus 50 and 19; 0 failures; only the known mlx-swift_Cmlx.bundle "missing creator" warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-suite-2.txt
    - next: /review. Not committed; task stays in doing.
  timestamp: 2026-11-19T09:16:31.302339+00:00
- actor: claude-code
  id: 01m7shkrycr8a95515ngdg72y4
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 1 finding (1 confirmed, 2 refuted) — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFForkPromptCacheIntegrationTests.swift:159. The 4 items of "## Review Findings (2026-11-19 03:06)" are fixed in f9ffd69c. Item 3: the test has a new bound on the next turn of the fork, and the doc comment names the production change (FoundationModelsLlamaCpp before c11b800). IntegrationTests/Package.resolved pins FoundationModelsLlamaCpp at c11b800b08f898ad5fcf1b970763497559468b9b.
    - next: implement the item of "## Review Findings (2026-11-19 03:17)": move the session construction and the RoutedSessionActor cast into the support file, and call it from Fixture.makeSource and the GGUF makeAnsweredSource.
  timestamp: 2026-11-19T09:18:42.636535+00:00
- actor: claude-code
  id: 01m7shmattzxnxm2tjtt67nayz
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — Support/ForkPromptCacheCopySupport.swift, GGUFForkPromptCacheIntegrationTests.swift, ForkPromptCacheCopyIntegrationTests.swift, LiveLLMContainerGGUFTests.swift (the new bound failed with llama.cpp 2a6b9d8)
    - test: green — one full swift test run, 3104 tests in 353 suites (+50, +19); GGUF suite 2/2 and MLX fork suite 11/11, each alone
    - commit: f9ffd69c
    - review: findings — GGUFForkPromptCacheIntegrationTests.swift:159 (the session construction and cast are still copied in both suites)
  timestamp: 2026-11-19T09:19:00.954570+00:00
- actor: claude-code
  id: 01m7shx4d04swtcqctc860xcrk
  text: |-
    Finding (2026-11-19 03:17, GGUFForkPromptCacheIntegrationTests.swift:159) fixed. Support/ForkPromptCacheCopySupport.swift now holds each step that both fork cache suites copied:
    - `RoutedModel<any LoadedLLMContainer>.makeRoutedSessionActor(instructions:tools:)` makes the session and casts it to RoutedSessionActor. `Fixture.makeSource` and the GGUF `makeAnsweredSource` call it. It is an extension member, not a top-level function (swift/immutability rule).
    - `AnsweredSource.instructions`: the terse instructions string. The two suites had the same string in two copies.
    - `MeasuredAnswer.replyTokenCeiling` (= GatedRealModelBudget.responseTokenCeiling). `MeasuredAnswer.answer(to:on:)` and `AnsweredSource.answering(_:then:on:)` no longer take `maxTokens`. The private `answer(_:on:)` wrapper and the `replyTokenCeiling` constant of each suite are deleted. The tests call `MeasuredAnswer.answer(to:on:)`.
    - `IsolatedPoolRouter.withForkingRouter(label:probe:resolving:_:)` makes the greedy router that records durably, runs `defer removeRoot()`, and calls `withResolved`. The GGUF `withProfile` and the fork `withFixture` call it. The fork suite now evicts the executor store before it makes the router; this order has no effect, because the router does not touch the store.
    The per-suite prompts and `Fixture.fork` (one forwarding line to `liveFork`) are not changed.
  timestamp: 2026-11-19T09:23:49.280546+00:00
- actor: claude-code
  id: 01m7shx7qas5hq0kee27ccdxhf
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/ForkPromptCacheCopySupport.swift, GGUFForkPromptCacheIntegrationTests.swift, ForkPromptCacheCopyIntegrationTests.swift. `swift build --package-path IntegrationTests --build-tests`: Build complete, no compiler warnings (only the SwiftPM "missing creator for mutated node" note for the mlx-swift_Cmlx bundle, which is not from this code). FoundationModelsLlamaCpp pin stays c11b800 in both Package.resolved files. `--filter GGUFForkPromptCacheIntegrationTests`: 2 tests in 1 suite passed. `--filter ForkPromptCacheCopyIntegrationTests`: 11 tests in 1 suite passed. No file outside IntegrationTests changed, so a full root `swift test` was not run.
    - next: /review. The task stays in doing.
  timestamp: 2026-11-19T09:23:52.682240+00:00
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

## Review Findings (2026-11-19 03:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFForkPromptCacheIntegrationTests.swift:160` `reuse/reuse` — `makeAnsweredSource(on:codeWord:)` repeats the flow of `Fixture.makeAnsweredSource()` in the fork suite: make a session, answer the first prompt, answer the second prompt, and return the source with its two answers. The same sequence of steps is written twice. Move the answered-source setup into the shared support file as one function that takes the session and the code word, and have both suites call it. Keep the per-suite prompts as parameters, so the GGUF suite passes its own code word.
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFForkPromptCacheIntegrationTests.swift:181` `reuse/reuse` — The `close(_:)` helper reimplements the `close(_:)` helper of ForkPromptCacheCopyIntegrationTests with the same body. Two copies of the same loop can drift apart, and a later change to close handling must be made twice. Move `close(_:)` into a shared extension in Support/ForkPromptCacheCopySupport.swift, such as `extension RoutedSession { static func close(_ sessions: [any RoutedSession]) async }`, or as a free function. Both suites then call the one helper and the private copies are deleted.
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFForkPromptCacheIntegrationTests.swift:198` `driver/fail-check` — `aForkAtTheLastCompletedTurnReusesTheHistoryAndTheSourceStaysAFullHit` cannot fail with the old llama.cpp behavior (FoundationModelsLlamaCpp 2a6b9d8). At 2a6b9d8, a hit takes the live record and keeps its usable prefix in the sequence. In this test, the fork takes the record of the source (a full hit at 2a6b9d8 and at c11b800). Then the next turn of the source takes the record of the fork and cuts it to the shared history, so its first call reuses the whole history of the source. Both bounds pass at 2a6b9d8. The doc comment says that "a fork that leaves the source no record, so the next turn of the source prefills its history again" makes the test fail; that is not true, because the source reuses the record of the fork. The only difference at c11b800 is that the record of the fork stays live (the source gets a "live_copy"). Add an assertion that only c11b800 satisfies: for example, after the source answered, a next turn of the fork reuses the whole history of the fork less `templateSeamTokens` (at 2a6b9d8 the source cut that record to the shared history). Then correct the doc comment so that it names the production change that makes the test fail.
- [x] `Tests/FoundationModelsRouterTests/LiveLLMContainerGGUFTests.swift:150` `reuse/reuse` — The new test builds a session backend with `LiveLLMContainer.make(wrapping:ref:)`, `makeSession`, and a cast to `MLXFoundationModelsSessionBackend`. The same three steps are already in `reasoningOffCallOnAGGUFContainerStatesTheNoThinkLevel`, so the setup is written twice in one file. Add a private helper in this suite, such as `makeBackend(of model: LlamaLanguageModel) throws -> MLXFoundationModelsSessionBackend`, that performs these three steps. Use it in both tests.

## Review Findings (2026-11-19 03:17)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFForkPromptCacheIntegrationTests.swift:159` `reuse/reuse` — The new GGUF `makeAnsweredSource` rebuilds the session by calling `model.makeSession(configuration:)` and then `#require(session as? RoutedSessionActor)`. The same construction and cast are in `Fixture.makeSource` in ForkPromptCacheCopyIntegrationTests.swift. This change moved the answering step into the shared `AnsweredSource.answering` but left this session-building step copied in both suites, so a later fix to one copy will not reach the other. Move the session construction into the support file next to `AnsweredSource`, for example `makeRoutedSessionActor(on model: RoutedLLM, instructions: String, tools: [any Tool] = [])`, and call it from both `Fixture.makeSource` and the GGUF `makeAnsweredSource`.
