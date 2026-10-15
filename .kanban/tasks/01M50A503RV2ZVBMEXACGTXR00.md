---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Count an answer toward mailOnlyAnswerLimit only when the model started a new background run in it
---
Do not start this task until the reviewer says so. Follow-up (a) of the task 11 review ^jrb5y4t (accepted: keep the limit and its rule).

Today an answer counts toward mailOnlyAnswerLimit when it delivered only run mail (a background run terminal or a ToolContext.message event). Thus a long agent tree with many child messages and no user input can reach the limit (for example 10 children x 10 messages that arrive one at a time), and the session pauses by mistake. Only an answer in which the model started a new background run can make a loop with no end.

Change: an answer counts toward mailOnlyAnswerLimit only when the model started a new background run in that answer. User-type mail still sets the count to zero. The default (100) and the pause behavior do not change.

- [ ] Fixed-order test: a chain of mail-only answers in which each answer starts a new background run reaches the limit and pauses.
- [ ] Fixed-order test: many mail-only answers that start no new background run (child messages and settlements only) do not pause. #elicitation-phase-3