---
position_column: todo
position_ordinal: '8180'
title: Stop a pass whose reasoning goes past a limit, and run a recovery that tells the model to act
---
## Problem

A reasoning model can think for a long time in one call, write no tool call, and never act. No setting of Router stops this before `passTokenLimit` (16,384 tokens). When a pass reaches that limit inside the reasoning, the answer ends with nothing: the next submission generates 0 tokens in 2 ms, and the turn ends.

Evidence: SWE-bench run of 2026-10-01 in FoundationModelsACPAgent. Two of the first 12 instances ended this way with no patch:

| Instance | Last call | Time | What the reasoning held |
|---|---|---|---|
| `django__django-13447` | fed 31,420, generated 16,384, "stopped at the token ceiling, left text" | 560 s | a counting loop (card: shape compare) |
| `django__django-14016` | fed 34,103, generated 16,384, "stopped at the token ceiling, left text" | 570 s | 64,659 characters: the model tried to remember the upstream fix ("upstream" 37 times, "remember" 19 times), and wrote about 45 python code blocks in its reasoning and never ran them |

For `django__django-14016` the repetition detector worked correctly: in each eighth of the reasoning, 36 to 85 of about 85 lines were new. This is not repetition. It is reasoning with no end.

Transcripts: `bench/preds.code-context.transcripts/<instance>/` in FoundationModelsACPAgent.

In the 10 instances of the same run that made a patch, the longest call was 9,584 tokens.

## What to do

1. Add `reasoningTokenLimit` to `RepetitionDetection` (or to a new settings value beside it): the most reasoning tokens of one generation pass. Proposed default: 8,192. A `nil` or `0` value sets no limit.
2. When a pass reaches the limit inside the reasoning, stop the call as the repetition stop does: keep the reasoning so far, and run a recovery submission with a short prompt that tells the model to act (make a tool call, or give the answer). Count it against `recoveriesPerAnswer`, or give it a count of its own.
3. When a pass reaches `passTokenLimit` inside the reasoning (`FinishReason.endedInsideReasoning` or `maxTokens` with reasoning only), run the same recovery, not a continuation that ends the answer with 0 tokens.
4. Emit a session event for the stop with its numbers (reasoning tokens, limit, recovery number), as `repetitionStopped` does, so a host can log it.
5. Name the stop in `FinishReason` when no recovery is left, so a host can map it to its own stop reason.

## Tests

- A scripted reasoning of 10,000 tokens with new lines and no tool call: the call stops at 8,192, a recovery runs, and the recovery prompt reaches the model.
- A reasoning below the limit that ends in a tool call: no stop.
- No recovery left: the answer ends with the named finish reason.
- The setting decodes with its default when the key is absent.

## Owner decision needed

The default value. 8,192 is a proposal from one run of 12 instances with `mlx-community/Qwen3.8-27B-mxfp4`. #generation-queue