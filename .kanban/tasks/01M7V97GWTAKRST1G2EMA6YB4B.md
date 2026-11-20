---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7v9eg60cn1b3g42prrajr6h
  text: |-
    Research: the call shapes of "a GGUF standard model with itself as its drafter drafts tokens" (file:line at HEAD 4eb67574).

    Load (LlamaLanguageModel.Options):
    - IsolatedPoolRouter.swift:48 gives `LiveModelLoader()`. LiveModelLoader.swift:1180-1182 gives `LlamaCppModelLoader(options: LlamaLanguageModel.Options(speculativeDecoding: true))`.
    - Extras cdc6179 LlamaCppModelLoader.swift:160-165 sets contextSize = the key context (the profile context 4096, GGUFProfileIntegrationTests.swift:45, through SlotPoolLoader.swift:93) and kvCacheType from the key (nil -> .float16; JointFit.swift:26 default nil).
    - maxLiveSequences = the default 4 (LlamaCpp 51bdabb LlamaLanguageModel.swift Options init; Runtime/ModelKey.swift:9). The Router never sets it.
    - drafter: the same GGUF file, ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf (GGUFProfileIntegrationTests.swift:98-106). LlamaCppModelLoader.swift:116-123 gives `drafter: drafter?.model` to LlamaLanguageModel.

    One RoutedSession, two LanguageModelSessions:
    - GGUFProfileIntegrationTests.swift:248 one `makeSession(instructions: "You are a terse assistant.")`, no tools; :251 one `streamEvents(to: ggufPrompt, maxTokens: 128)`. The second call is an internal recovery of the same answer, not a second submission by the test.

    Call 1:
    - Transcript: [instructions "You are a terse assistant.", prompt "Count from one to twenty in words, separated by commas."].
    - GenerationOptions: LiveModelLoader.swift:298 `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128)` (ResponseTokenCeiling.swift: a requested ceiling is used as is). No guide (no grammar, stream path LiveModelLoader.swift:722-731), no tools.
    - ContextOptions(): no reasoning level (LiveModelLoader.swift:728-730), so the template thinks.
    - End: a normal end at maximumResponseTokens in the engine (FinishReason .maxTokens, "stopped at the token ceiling", GenerationCallUsage.swift:169). Not a cancel: the watch reasoning limit is 8192 (RepetitionDetection.swift:53), and the stop is found after the call ended (RoutedSessionActorReasoningStop.swift reasoningEndStop).

    Between the calls:
    - continueAfterReasoningEnd -> closeStoppedReasoning -> replaceRender (RoutedSessionActorRepetitionWatch.swift:696-702) -> backend.replacingTranscript (LiveModelLoader.swift:914-920): a NEW LanguageModelSession, made with `LanguageModelSession(model:tools:transcript:)` over a new SessionLanguageModel wrapper of the SAME LlamaLanguageModel instance.

    Call 2:
    - Transcript (the seed): [instructions, prompt ggufPrompt, reasoning of call 1 (128 tokens), the response entry that call 1 left (if any), response "(The session stopped this reasoning here.)" (RoutedSessionActorRepetitionWatch.swift:319, RepeatedPartRemoval.swift:32-46)], then the new prompt "Stop reasoning. Your next output must be your final answer." (answerOnlyRequest, RoutedSessionActorRepetitionWatch.swift:236 and :126-127, no tools).
    - GenerationOptions: the same, greedy, maximumResponseTokens 128 (runContinuation keeps the ceiling, RoutedSessionActorAnswerExecution.swift:612-623). No guide, no tools.
    - ContextOptions() with the first pass reasoningLevel = .custom("no_think") (ReasoningOffRequest.swift:38, LiveModelLoader.swift:733-737, SessionLanguageModel.swift:278-289). LlamaLanguageModel reports switchable reasoning (LiveModelLoader.swift:209-218).
    - The Qwen3.5 template drops the reasoning of an assistant turn before the last user message, which agrees with "fed 69 tokens (28 cached)".

    Other GGUF drafter tests: none. ggufAnswersWithMTP already checks fallbackReason == nil on each call. MTPDrafterIntegrationTests is MLX.
  timestamp: 2026-11-20T01:34:30.080050+00:00
- actor: claude-code
  id: 01m7v9rbzmpcxxzsyf4cphbn5v
  text: |-
    Test change (GGUFProfileIntegrationTests.swift, ggufAnswersWithItselfAsDrafter): `try #require(calls.count > 1)` (the recovery call must be there), and on each call, in addition to the existing tokensOut > 0 and draftedTokenCount > 0 checks: `#expect(outcome.fallbackReason == nil, ...)` and `#expect(outcome.acceptedDraftTokenCount > 0, ...)`. The suite doc item 3 now says that each call drafts with no fallback, the first call and the recovery. No other GGUF drafter test has this gap (ggufAnswersWithMTP already checks fallbackReason == nil on each call; MTPDrafterIntegrationTests is MLX).

    Run at FoundationModelsLlamaCpp 51bdabb, Extras cdc6179 (rebuilt first): 3 passed, 1 failed. The self-drafter test fails at the new check `outcome.fallbackReason == nil` (GGUFProfileIntegrationTests.swift:344). Calls: [fed 33 (0 cached), generated 128, stopped at the token ceiling, MTP accepted 95 of 95] then [fed 69 (28 cached), generated 69, ended by the model, MTP fell back to plain decode: draftOutOfSync]. The draftedTokenCount > 0 and acceptedDraftTokenCount > 0 checks of call 2 pass, so call 2 drafted and accepted some tokens before the fallback. The MTP tests (no drafter) draft on both calls (88/117, then 51/54). Output: scratchpad/test-51bdabb.txt.

    Run at FoundationModelsLlamaCpp 2a6b9d8 (before c11b800), rebuilt (the FoundationModelsLlamaCpp module compiled again): the SAME result. Call 2 falls back with draftOutOfSync; the same 3 passed, 1 failed, and the same token counts. So c11b800 / 51bdabb did not cause the fallback. Output: scratchpad/test-2a6b9d8.txt.

    What did not work: `swift package resolve FoundationModelsLlamaCpp --revision 2a6b9d8` fails with "required using two different revision-based requirements (2a6b9d8 and main)", because the manifests name the package at `branch: main`. `resolve ... --branch main` does not move a pin that already names branch main. What worked: set the revision in IntegrationTests/Package.resolved (git-ignored; no manifest change, no root pin change) and run `resolve`, then put the saved 51bdabb copy back and `resolve` again.

    Final pin: IntegrationTests/Package.resolved names FoundationModelsLlamaCpp 51bdabb and Extras cdc6179, the checkout is at 51bdabb, rebuilt. No Router source change, no root pin change, no commit.

    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/GGUFProfileIntegrationTests.swift. 51bdabb: 3 passed, 1 failed (new check, call 2 draftOutOfSync). 2a6b9d8: same failure. Final pin 51bdabb, rebuilt.
    - next: /review. Then send the call shapes and the two results to foundationmodelsllamacpp-44 (task "After"); commit the test change; push only when the llama.cpp fix lands or the user wants CI to show the case.
  timestamp: 2026-11-20T01:39:53.460139+00:00
- actor: claude-code
  id: 01m7v9swb2kw59czvw2kwenqka
  text: |-
    ### finish iteration 1 — stuck (waits for FoundationModelsLlamaCpp)
    - implement: changed — GGUFProfileIntegrationTests.swift: the self-drafter test now requires calls.count > 1 and, on each call, fallbackReason == nil and acceptedDraftTokenCount > 0.
    - facts: call 2 is a recovery inside the same answer (a new LanguageModelSession over the same LlamaLanguageModel, transcript replaced, first pass reasoningLevel .custom("no_think")), not a new session. Call 1 ends normally at maximumResponseTokens 128. Options: speculativeDecoding true, contextSize 4096, maxLiveSequences default 4.
    - test: red as expected — GGUFProfileIntegrationTests alone: 3 passed, 1 failed at :344 (call 2 draftOutOfSync) at 51bdabb; the same failure at 2a6b9d8, so the fallback is older than c11b800.
    - commit: none yet (the change is in the working tree; it stays red until the llama.cpp fix).
    - next: sent the shapes to foundationmodelsllamacpp-44. When its fix lands: update the IntegrationTests pin, rebuild, run GGUFProfileIntegrationTests alone once, commit, review, push.
  timestamp: 2026-11-20T01:40:42.978789+00:00
position_column: doing
position_ordinal: '80'
title: The self-drafting GGUF test also checks its second call, and the Router gives llama.cpp the exact call shapes (draftOutOfSync)
---
## Problem

With FoundationModelsLlamaCpp 51bdabb, the Router integration test "a GGUF standard model with itself as its drafter drafts tokens" (`IntegrationTests/.../GGUFProfileIntegrationTests.swift`, Qwen3.5-0.8B-Q8_0.gguf as its own drafter) passes, but its second call falls back: `fed 69 tokens (28 cached), generated 69 tokens, ended by the model, ... MTP fell back to plain decode: draftOutOfSync` (its first call: `fed 33 tokens (0 cached), generated 128 tokens, stopped at the token ceiling ... MTP accepted 95 of 95 drafted tokens`). The test checks only the first call. foundationmodelsllamacpp-44 cannot repeat the fallback (its new integration test ccfc4e5 drafts in the same shape it guessed) and asks for details.

## Work

1. Find and write down the exact shape of call 1 and call 2 of that test: the transcript entries of each (instructions, prompts; same session or a new session), the `GenerationOptions` (maximumResponseTokens, sampling, guide, tools), the reasoning level / `ContextOptions`, how call 1 ends at the ceiling (a normal end at maximumResponseTokens, or a cancel), and the `LlamaLanguageModel.Options` of the self-drafting profile (maxLiveSequences and the others). Read the test, the profile fixture and the Router GGUF path (`Resolution/`, `LiveModelLoader.swift`).
2. Add a check that the second call drafts (no fallback reason) to that test, and to any other GGUF drafter test that has a second call with the same gap. Keep the first-call checks.
3. Run `GGUFProfileIntegrationTests` alone once with FoundationModelsLlamaCpp 51bdabb (expected to fail on the new check). Then pin IntegrationTests to 2a6b9d8 (before c11b800) with `--manifest-cache local`, run the same suite alone once, and pin back to 51bdabb. Record whether the second call falls back at 2a6b9d8.

## After

Send the call shapes, the two results and the test change to foundationmodelsllamacpp-44. Commit the test change. Push it only when the llama.cpp fix lands and the test passes, or push it at once if the user wants the CI to show the case (the llama.cpp session asked for the check in CI). #ci #d205