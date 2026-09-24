---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'FoundationModelsACPAgent: map FinishReason.endedInsideReasoning to a stop reason'
---
## Context

^gfxd7av adds a new case to Router `FinishReason`: `endedInsideReasoning`. It means "the output ended inside the reasoning before the ceiling". Before ^gfxd7av, Router reported this stop as `.maxTokens` ("stopped at the token ceiling"). The ACP agent then ended the turn with `_truncated`.

Now `.maxTokens` means only one thing: the last generation call spent its whole token ceiling. A call that ends inside `<think>` below the ceiling gets `.endedInsideReasoning`. Router does not compact after `.endedInsideReasoning` and does not send `ceilingStopContinuationPrompt`.

Evidence: run django__django-13964, seq 132 (39,617 of 262,144 tokens) and seq 225 (12,182 of 262,144 tokens). See the research comment on ^gfxd7av.

## Work (in the FoundationModelsACPAgent repo, not in this repo)

`FinishReason` is a public enum with no library evolution. A `switch` over it with no `default` arm does not compile after the Router update.

- [ ] Find each `switch` and each comparison over `FinishReason` / `TokenUsage.finishReason` / `GenerationCallUsage.finishReason` in FoundationModelsACPAgent.
- [ ] Map `.endedInsideReasoning` to an ACP stop reason that says what occurred. Do not map it to the ceiling stop (`max_tokens` / `_truncated` for the ceiling), because the ceiling did not stop the call.
- [ ] Write a failing test first for the mapping, then change the code.
- [ ] Update the Router pin in `Package.resolved` to the commit that holds ^gfxd7av.

## Rules

- No new limit and no new constant.
- A detector for a call that repeats itself is ^1hcwaqy, not this task.