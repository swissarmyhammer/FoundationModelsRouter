---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: close() called from a tool body of the same session deadlocks
---
Do not start this task before ^pjycptw is done.

When a tool body of a session calls close() on the same session, close() never returns:
- For a background run, runDrain() waits for runPlane.joinRunBodies() (RoutedSessionActorDrain.swift ~:206), and that waits for the body of the same run, which is the caller of close().
- For a synchronous call inside an answer, runDrain() waits for the pump (Drain ~:210-211), the pump waits for the answer, and the answer waits for the tool.
The doc of close() (RoutedSession.swift ~:624-667) does not forbid this call.

- [ ] Fix, one of: (a) detect that the caller is a run body or a tool call of this session (for example through the run token in ToolContext.current) and refuse the call with a clear error; or (b) start the close in a detached task and return. Choose one and record the reason.
- [ ] Update the doc of close() for the rule.
- [ ] Fixed-order test for a background run and for a synchronous tool call: no hang, and the chosen result (the error, or a close that ends after the tool returns). #defect