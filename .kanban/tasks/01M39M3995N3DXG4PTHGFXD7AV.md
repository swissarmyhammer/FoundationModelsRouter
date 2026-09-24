---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: One generate call can generate tens of thousands of tokens before it stops at the ceiling
---
## Evidence

Transcript: `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/bench/preds.t90.transcripts/django__django-13964/01M38ATWY3RB45SQSYD5BX53P8/transcript.jsonl` (read the `generationCall` records). Model mlx-community/Qwen3.8-27B-mxfp4, window 262,144, compaction trigger 0.8. Router bbad3ce.

- There were 31 generation calls in one turn. Fed tokens went from 4,064 to 43,912. The largest real context (fed plus generated) was 59,672 tokens, 0.228 of the window. The compaction trigger (209,715 tokens) was never near.
- Two calls generated much more than the other calls. Each record says "stopped at the token ceiling":
  - seq 132: fed 20,055, generated 39,617. It ran from approximately minute 2.3 to minute 25.8 of the turn.
  - seq 225: fed 43,912, generated 12,182.
- Each of the other calls generated between 56 and 9,529 tokens.
- After seq 225, the turn ended with the stop reason `_truncated` and no edit. The run used 2,741 s of agent time and made an empty patch.

## Questions

1. Which ceiling stopped seq 132 at 39,617 tokens and seq 225 at 12,182 tokens? The two values are different, so the ceiling is not one fixed number. The window had more than 200,000 tokens of room in both calls, so the window did not stop them. Examine commit 0bb3bb5 ("send the window of the model when a call names no ceiling") and the ceiling that the ACP agent sends.
2. The fill value (`contextFill=1.877`) is the subject of ^tpsc0nf. It is a sum across the calls of an attempt. Because of it, the ceiling stop at seq 132 caused a compaction that was not necessary.
3. What must occur when one call generates this much without a tool call? Possible answers: continue after the ceiling stop, set a lower bound, or a different action. Per the rule "no invented limits", a new bound is the decision of the user.

## Source

A peer session (foundationmodelsacpagent-e5) reported this run.