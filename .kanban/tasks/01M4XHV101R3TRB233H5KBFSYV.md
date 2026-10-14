---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Session work events and user-wait idle (elicitation Router tasks 9 and 10)
---
Source: elicitation-plan.md, Router tasks 9 and 10. Do not start this task. It is not in the mail plan.

(10) Add two session events on the output stream. They are in order with the other outputs and have the origin .system:
- One event when the session gets work while it had no work.
- One event when the session has no work any more.
Use the same rules as awaitIdle(). Send one event for each change of the work, so that a consumer needs no clock and no poll.

(9) A run that waits only for the user does not count as work, for isIdle() and for these events. hasPendingOperation does not change.

Depends on Extras task 15 (each open question linked to its run token). The Extras card for task 15 is 01M4XHV11H4PHS5ATFT8EF14F9 (^8ef14f9) on the Extras board.

Found by ACPAgent step 4 T5 (^4pjhz63): awaitIdle() is not in order with streamSessionEvents(), and no event tells a change of the work. #elicitation-phase-1