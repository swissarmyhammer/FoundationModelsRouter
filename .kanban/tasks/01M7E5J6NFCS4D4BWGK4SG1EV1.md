---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffff9380
title: Nudge an answer that ends with a waiting status while nothing is pending
---
## Problem

On flint4 django-13447, root 01M7E3Q75PZBQC0WHM78M40G5P got the result of its review agent as a tool output (seq 2611). In the next pass (seq 2612) it wrote "Waiting on the review double-check agent. Its completion token is `01M7E507Q7TJ09AEP24YS5T1TH`." (that is the child session id, not the completion token). Nothing was pending, so the answer ended, and the committer never ran.

## Fix

The router now checks the final text of an attempt that the model ended. When that text opens with `PendingRunEnvelope.waitingStatusPrefix` ("Waiting on", Extras 9915ea2) and `hasPendingOperation()` is false, the answer goes on one time with `staleWaitPrompt`. The nudge runs once per answer.

The check matches the instructed status wording and not tokens, because the model quoted the child session id, not the completion token.

## Test

`StaleWaitNudgeTests`: one nudge, and a second waiting status ends the answer.