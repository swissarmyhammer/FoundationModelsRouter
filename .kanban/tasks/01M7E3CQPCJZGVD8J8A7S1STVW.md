---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffff9180
title: Keep the tool work of an attempt when a rejected tool call ends it after a tool result
---
## Problem

A rejected tool call (`RejectedToolCallError`, for example an undeclared tool such as `shell`) retried the attempt with the original prompt again. `LanguageModelSession` keeps no entry of a call that throws, so a rejection in pass N of a tool loop lost every tool call and output of passes 1…N-1, and the model started the task again from its prompt alone.

Recursive Flint on django-13447 hit this in 11 of 23 child sessions across flint1–3 (Qwen: 1 of 238). The coder 01M7E2DMGXTN29WB07P8R3T814 (flint3) loaded its skills and ran `detectProjects`, then called `shell` (seq 1421 "fed 0 tokens" is the rejected pass). The retry (seq 1440, fed 4156 tokens with 0 cached) had only the coder prompt, wrote "I will …" and ended the answer, so flint3 ended with an empty patch. The run log has the line "a rejected tool call goes back to the model … tool.name=shell, undeclared_tool".

## Fix

- `ToolResultWatch.boundaryEntries` is the backend transcript read at the newest tool result of the session's own open model call.
- A rejection with a boundary rebuilds the attempt (`recordAttemptStoppedAtRound`) and goes on with only the tool error as its prompt (`continueAfterRejectedCall`).
- A rejection in the first pass keeps the old retry, because it loses nothing.

## Test

`RejectedToolCallRetryTests`: "a rejection after a tool result keeps the work of the attempt". It was red before the fix and is green after it.