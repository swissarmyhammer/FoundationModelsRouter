---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7fhar1nwyrzaqg4dzqj0xge
  text: |-
    ### Decision (user, 2026-11-15): won't do
    "having it happen one time isn't a reason". The one occurrence (flint3 django-13447) was a side effect of the rejected-call context loss fixed in ^7s1stvw. Reopen only if intent-only endings recur.
  timestamp: 2026-11-15T12:01:22.485963+00:00
position_column: todo
position_ordinal: '8380'
title: Nudge an answer that ends with only intent text ("I will …") and no tool call
---
## Problem

The router takes a turn that ends with only future-tense intent text and no tool call as the final answer, even when the turn did no work. On flint3 django-13447, coder 01M7E2DMGXTN29WB07P8R3T814 seq 1441 answered "I will find the admin app list code now. I will read the source file first. I will search for the method name." and the answer ended 10 s after its start with no change. (The root cause there was ^ the rejected-call context loss, but the end of the answer is a separate gap.)

## Wanted

A recovery nudge, like the one for empty answers. When an answer in a session with tools ends with text that only states intent, and the answer made no tool call, send one continuation that says "Do it now: make the tool call", within the recovery budget.

## Notes

- How to detect it is open. A plain text heuristic is fragile and STE-styled output says "I will" a lot. Consider using the decision model (h2o-lightning-4b) to answer "does this text only state what the agent will do next?" Consider requiring zero tool calls in the answer.
- Use hermetic tests only.