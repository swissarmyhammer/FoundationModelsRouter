---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m711kbwtrjysp25xje8qc2fd
  text: |-
    Model choice notes from FoundationModelsLlamaCpp:
    - Use the ggml-org conversion `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf`, which keeps the MTP layers. Unsloth's regular GGUFs drop them; only its `-MTP-GGUF` repos keep them.
    - LlamaCpp's full serial real-model suite passed at c4ae2ab (77 tests). A seeded temperature-0.8 run also gives identical tokens with and without speculation.
    - A DFlash drafter with a real speedup has been tested only as Qwen3.5-4B + Anbeeld/Qwen3.5-4B-DFlash-GGUF, which LlamaCpp is adding now. It is too large for the 2-minute budget, so use MTP and the model-as-its-own-drafter case here.
  timestamp: 2026-11-09T20:57:05.690505+00:00
- actor: claude-code
  id: 01m71550194dh7jd3q48t9nh7b
  text: |-
    Research (implement):
    - Gating: the IntegrationTests suites read NO environment variable; the nested package boundary selects them, and each suite carries `.exclusiveRealModel` (GatedSuiteSerialGate permit + per-test wall clock). No env gate to add.
    - `Router.resolve` always fills all three slots (standard, flash, embedding), and flash must differ from standard. So a GGUF-standard profile also needs a flash and an embedding candidate: plan is `mlx-community/Llama-3.2-1B-Instruct-4bit` (flash, the suites' small model) and `RealModels.embedding`.
    - Teardown pattern for a router-built profile: own `ModelPool()`, `profile = nil`, then `pool.awaitNoResidentModel()` (PromptCacheBudget/CrossRouterPool). `RealModelContainer.evict` only evicts MLX; `LlamaCppModelLoader.evict` is a no-op (llama.cpp registry unloads after its idle timeout).
    - Chat-template date: the Qwen3.5-0.8B GGUF template reads no date (only `enable_thinking`), and llama.cpp renders it, so no date pin applies to the generating model; the PinnedDateTokenizerLoader pin is MLX-only.
    - MTP: `LlamaLanguageModel.Options.speculativeDecoding` defaults to true, so a GGUF with nextn layers drafts with no drafter; the executor writes `speculativeDecoding`/`draftedTokenCount` response metadata, which the router reads into `GenerationCallUsage.speculativeDecoding` (SessionEvent.generationCall).
    - The GGUF is already in the HF cache at snapshot 807dfd9a (from the LlamaCpp suite); Llama-3.2-1B is not cached on this box.
    - ResolutionProgress exposes only `chosen` per slot (no per-candidate report on success).
  timestamp: 2026-11-09T21:59:09.097074+00:00
- actor: claude-code
  id: 01m715vgd80tp00y5jvcc0z1hd
  text: |-
    Implementation landed: IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFProfileIntegrationTests.swift (suite GGUFProfileIntegrationTests, `.serialized` + `.exclusiveRealModel`). Each test has its own router, a LiveModelLoader, and its own ModelPool, with greedy sampling and context 4096. Teardown: `profile = nil`, then `pool.awaitNoResidentModel()`.
    - Case 1: profile standard=[GGUF], flash=[Llama-3.2-1B-Instruct-4bit], embedding=[RealModels.embedding]. One answer at maxTokens 128. Every generation call is checked for tokensIn>0, 0<tokensOut<=128, speculativeDecoding.speculated, and fallbackReason==nil.
    - Case 2: same profile, but standard = the GGUF with itself as drafter. Every call has draftedTokenCount>0.
    - Case 3: standard=[RealModels.standard (17 GB MLX, sized only, never downloaded), GGUF], over a FixedWorkingSetProbe at 8 GiB. The slot report (`standard.resolution.considered`) reads [tooLarge, chosen], and the chosen ref is the GGUF.
    What did not work: the first run expected exactly one generation call per answer and failed. Qwen3.5 reasons for the whole 128-token pass, so the router's reasoning-stop recovery makes 4 calls in one answer. The test now checks every call. That is not a router bug, but it showed a gap: the reasoning-off final pass cannot reach a llama.cpp model (no ReasoningSwitchable conformance, and LlamaCpp has no reasoning-off level). Filed as ^r0dx34s.
    Also found: the self-drafter resolve sizes for 15–20 s, against ~5 s for the plain ref. Filed as ^vf5brrc.
    No router bug needed a Sources fix; Sources are unchanged.
  timestamp: 2026-11-09T22:11:26.760568+00:00
- actor: claude-code
  id: 01m715vm32f7v2napydxvs19xs
  text: |-
    ### implement — changed
    - evidence: 1 file, the new IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFProfileIntegrationTests.swift. Real-model runs of `swift test --package-path IntegrationTests --filter GGUFProfileIntegrationTests`: run 1, the first draft, failed (expected 1 generation call, got 4) after 348 s, which included a 4.5-minute Llama-3.2-1B download. With the final code: run 2 passed (3/3, suite 62.1 s, command 82 s; tests 11.9 s / 38.8 s / 11.3 s). Run 3, back to back, passed (3/3, suite 64.3 s, command 77 s; tests 12.0 s / 40.3 s / 11.9 s). Root `swift build --build-tests`: clean apart from the known mlx-swift_Cmlx.bundle notice. Root `swift test`: 2508 + 38 + 19 = 2565 passed.
    - next: /review
  timestamp: 2026-11-09T22:11:30.530080+00:00
- actor: claude-code
  id: 01m7160k0h8641ax6eeygt64b8
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (12113453): 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed); 1 file reviewed (GGUFProfileIntegrationTests.swift), 10 .kanban files excluded by .reviewignore. Acceptance item checked: runs 2 and 3 back to back were 3/3 each (62.1 s, 64.3 s).
    - next: none — task moved to done.
  timestamp: 2026-11-09T22:14:13.265036+00:00
- actor: claude-code
  id: 01m7160yd4dgnmhrcy4hjc0kqb
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — GGUFProfileIntegrationTests.swift (new); real-model runs passed 3/3 twice in a row (62.1 s, 64.3 s)
    - test: green — swift test 2565 passed, IntegrationTests builds
    - commit: 12113453
    - review: clean — 0 findings
  timestamp: 2026-11-09T22:14:24.932106+00:00
depends_on:
- 01M70TBC964F3BW0TM6YQ9T4ZD
- 01M70TBJ05VAPRAC8DEZ27872M
- 01M70TBSAB9VECTCB9R7K8WTQ6
position_column: done
position_ordinal: fffffffff380
title: 'GGUF: real-model integration test — a GGUF profile resolves, generates, and speculates with MTP'
---
## What
A gated test in the IntegrationTests package that drives the whole router path with `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` (Extras and LlamaCpp tested with this ref, and it has nextn layers):
- `Router.resolve` of a ProfileDefinition whose standard slot is that ref. No backend is named anywhere.
- A session answers. Use greedy sampling and maximumResponseTokens around 128, and check token counts rather than the answer text: Extras saw Qwen3.5 sometimes spend its whole budget on reasoning.
- `GenerationCallUsage.speculativeDecoding?.speculated == true` with no drafter (MTP). A second case uses the model as its own drafter and checks draftedTokenCount > 0.
- A mixed profile, with an MLX candidate and the GGUF candidate, resolves by fit.
- Keep it under the 2-minute budget per integration test.

## Acceptance
- [x] The test passes twice in a row locally. #gguf