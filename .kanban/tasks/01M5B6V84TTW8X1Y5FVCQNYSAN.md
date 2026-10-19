---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffff9880
title: The delegate hint reaches the model as a session prompt at a stop of the model call, not as tool-result text
---
From foundationmodelsacpagent-a5. In live run agents-16, instance django__django-13447, the hint fired on time but the model ignored it. The agent's Safety rule treats any text inside a tool result as data, so the hint read as data.

Plain mail can't fix this: it joins a running answer only at a continuation submission, and the next one would come only after the whole answer.

Design (follows the no-op stop and the compaction yield):
- The decorator only counts outer calls. The witness still counts inner calls.
- At the tool-result boundary (`ToolResultAppendBoundary`) of the session's own open model call, when the round of tool calls is complete and the hint is due, the session sets a DelegationHintStop and cancels the model call.
- On the failure: rebuild the transcript with every result of the round, record it, then run one continuation submission whose prompt is "Your tool results are above. " + hint.
- Another stop that fires at the same time wins, and the hint stays due.
- Unchanged: once per root session, no hint in a child session, no lease and no mail.

TDD with a scripted tool-loop model.