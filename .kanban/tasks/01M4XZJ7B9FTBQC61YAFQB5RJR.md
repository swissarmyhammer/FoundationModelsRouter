---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Session event elicitationEnded for a question that ends without a client answer
---
Do not start this task until the Extras tasks 16 and 17 are done. This task fixes the ACPAgent gap ^crjmk34. It goes with workStarted and workEnded in one consumer step (Agents demo, ACPAgent translator and tests, Multitool ScenarioRunner).

Add a public SessionEvent case `elicitationEnded`. It carries:
- the elicitation id, which is the same ULID as in `elicitationRequested`,
- how the question ended: cancelled or declined, with the reason (Extras task 16).

The session sends it when a question leaves the run plane without a client answer, in order with the other outputs. elicitationEnded never comes for a question that the client answered.

Origin and order for each way that a question can end:
- Run cancel (`cancel(completionToken:)`, Extras task 17, reason "run cancelled"): origin `.mail([id])` of the run's mail, like the other run output events. It comes before the terminal event of that mail.
- `cancelAll()`: origin `.signal(id)` of the cancel-all signal, because the outputs of the silenced mail are dropped. It comes before the terminal event of the cancel-all signal.
- `close()`: origin `.system`. It comes before the output stream ends.

Depends on Extras tasks 16 (a reason in decline and cancel) and 17 (resolve the open questions of a cancelled run with cancel and the reason "run cancelled"). The reviewer asks Extras to add those cards.

Tests: one fixed-order test for each way to end; no event for an answered question; the event id matches the id of `elicitationRequested`. #elicitation-phase-1