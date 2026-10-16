---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: close() of a parent from a tool of a child whose answer a parent tool waits for deadlocks
---
Found in ^3jpewc9.

A tool of session P calls child.respond(...) on a child session C (a fork, or another session). A tool of C then calls P.close(). P.close() waits for the end of all work of P, and that work includes the tool of P, which waits for the answer of C, which waits for the tool of C, which waits for P.close(). So the close never returns.

The fix of ^3jpewc9 (SessionOwnWork, a task-local set of session ids bound at the submission of each model call) does not cover this case: the pump of a session is `Task.detached` (wakePump), so the answer of C does not inherit the set of the tool of P. The doc of RoutedSession.close() now tells hosts not to do this.

- [ ] Decide: carry the SessionOwnWork set of the sender with the mail into the submission of the answer (respond/send from a tool), or refuse the call, or keep the documented rule only.
- [ ] Fixed-order test for the chosen result, with no hang.
#defect