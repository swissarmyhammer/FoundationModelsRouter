---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffff9c80
title: Repeated-tool-call nudge must not offer "your final answer" as an exit
---
Reported by ACPAgent from the flint24 bench. In django__django-14411 the root called `skills {id: do-task, op: "read", path: references/code.md}` three times. "read" is not a skills op, so each call returned "Unknown operation". The third identical call tripped the repeated-tool-call stop (watchStop repetition, repeatedToolCall count 3, toolName skills). The recovery prompt `repeatedToolCallContinuationPrompt` ends with `repetitionStopActRequest` ("...one tool call that makes the change you decided on, or your final answer."). Flint took the final-answer exit: "I stopped the task. I did not call the skill tool again. I did not change the code." The result was an empty patch in 23 s.

Fix: the recovery prompt for a repeated tool call does not offer a final answer. It points the model at a different call: read what the tool's output says (for example a wrong op and the valid ones it lists) and call again with corrected arguments, or call a different tool. The final pass, used once no recovery is left, still allows a final answer.

Evidence: FoundationModelsACPAgent/bench/preds.flint24.transcripts/django__django-14411/01M7HVRCF99YJX9YKREQ3PEAZW/transcript.jsonl seq 55227-55241. #bug