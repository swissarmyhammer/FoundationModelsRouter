---
assignees:
- claude-code
depends_on:
- 01M39ZP766H4S63AR4R44Y6BA4
position_column: todo
position_ordinal: '8780'
title: 'Design: deliver mailbox events and check compaction at each pass, not only at the start of a request'
---
## Why

With the per-model queue, the pass is the real unit of work. But two behaviors still use the request ("turn") as their unit:

- **Mail.** The outbox and the mailbox go into the prompt only at the start of a request (`finishTurnAndRequeueIfUnattached` in `Session/RoutedSessionActorRecording.swift`, and `dispatchNextPrompt()`). A model in a long tool loop does not see a finished child run until its request ends. This is why agents need the "end your turn to wait" text.
- **Compaction.** The check at the start of a request, plus compaction at a tool result or at a ceiling stop (`Session/RoutedSessionActorCompactionYield.swift`). `compactionYieldsStopped` resets one time for each request.

Design context: `generation-queue.md`.

## Questions to answer (the output of this task is a written design, not code)

1. Can the Router add mail to the transcript between two passes of one attempt? The SDK owns the tool loop. Find the seam: the tool-result append boundary (`ToolResultAppendBoundary`), a pass-level hook in the per-session queued executor wrapper of ^8csj2hw, or a stop-and-continue attempt as the compaction yield does now.
2. In what form does the model see mail between passes: a tool output, an extra user entry, or a system note? What does each form do to the KV prompt cache (a prefix change forces a full prefill)?
3. Can compaction use the same seam, so there is one boundary mechanism for mail and compaction?
4. What happens to `TurnBoundaryTool.turnWillBegin()` (now called one time before the model call)? Keep it at the request, or call it at each pass?
5. What does FoundationModelsAgents need (ask that session): does mail at each pass remove its need for "end your turn to wait"?

## Acceptance Criteria

- [ ] A design note, as a comment on this task, answers questions 1-5 with evidence (file and symbol names; line numbers only with the commit they were read at).
- [ ] A spike test proves the chosen seam can add one entry between two passes of one attempt.
- [ ] Implementation tasks are on the board, or a comment tells why the change is not worth doing. #generation-queue #design