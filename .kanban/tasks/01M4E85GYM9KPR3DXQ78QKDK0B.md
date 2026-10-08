---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Restore a hybrid checkpoint at the end of the prompt when the next render drops the last generated turn, so the Qwen 3.5 cache does not rebuild
---
## Origin

foundationmodelsacpagent-19 sent this request from a SWE-bench run of FoundationModelsACPAgent (2026-10-08). It is separate from ^v3dt28p. The cache code is in the fork `../mlx-swift-lm` (branch `stable`): `Libraries/MLXFoundationModels/ExecutorPromptCache.swift`, `Libraries/MLXLMCommon/PromptCacheReusePolicy.swift`, and the executor in `Libraries/MLXFoundationModels/MLXLanguageModel.swift`. Router causes the dropped turn in `Sources/FoundationModelsRouter/Session/RejectedToolCallRetry.swift`.

## Evidence

File `bench/cacheplan.code-context-1008.log` in FoundationModelsACPAgent, session 01M4E78R5ZQHF2DQSHDDPH6N78, instance django__django-14238:
- 12:07:53.431 `rendered=30675 reused=0 fed=30675 rule=rebuild divergence=30601`
  - render at the divergence: `user\nYou called \`runCode\` with the same arguments…`
  - ledger at the divergence: `assistant\n<think>\n\n</think>\n\n<tool_call>\n<function=run…`
- 12:09:39.574 `rendered=31125 reused=0 fed=31125 rule=rebuild divergence=30669`
  - render: `user\n[execute] execute shell (01M4…`
  - ledger: `assistant\n<think>\n\n</think>\n\n<tool_call>\n<function=run…`
- The log has the `RejectedToolCall` warning at 08:07:22 and at other times.

## What happens

1. The model writes a turn (a repeated `runCode` call). The cache commits that turn.
2. Router rejects the call. The next render does not contain that assistant turn. In its place, there is a user correction ("You called `runCode` with the same arguments") or a mail line.
3. The two token lists are the same up to token 30,601. They are different only in the last ~74 tokens. But the recurrent layers cannot rewind. Thus `reused=0`, and all 30k tokens go through prefill again.
4. Each rejected repeat call, and each turn that Router drops, costs one full prefill on this model.

## Fix

- Take a checkpoint of the recurrent state at the end of the prompt, before generation starts.
- When the next render is the same as the prompt of that turn up to its end, and differs only after it, restore the checkpoint and feed only the new tail. The plan must then say `rewind` (or a checkpoint restore), not `rebuild`.
- Card ^xx5g893 in mlx-swift-lm describes this design: commit e78994c, "split-prefill hybrid checkpoints at the transcript-stable boundary". llama.cpp also keeps a checkpoint before the end of the prompt. Examine that commit first, and use its checkpoint mechanism if it applies.
- Do not add a new hard-coded limit. If the checkpoint needs memory that a limit must control, record the question on this card for the user.

## Acceptance

- Scripted hybrid model test: a turn whose generated tokens the next render drops and replaces with a user message logs `rule=rewind` (or a checkpoint restore), with `reused` equal to the prompt length of that turn. It must not log `rule=rebuild`.
- mlx-swift-lm tests pass, and Router `swift test` passes.
- Real-weights check with `mlx-community/Qwen3.8-27B-mxfp4`: run it only after the SWE-bench run of foundationmodelsacpagent-19 ends.

## Note

The ledger turn starts with `<think>\n\n</think>`. Thus that session had thinking off after a stop (see ^bhdj5v9).

## Process blocker

The review skill rule "Review Only This Repository" stops a review of mlx-swift-lm from the Router session. ^v3dt28p is stuck for this reason. The same decision applies to this task. #cross-repo #needs-fork #prompt-cache #real-model