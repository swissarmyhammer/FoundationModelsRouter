---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffdc80
title: 'G: run mail ids on the run output events (mail step 2, part G)'
---
Part G of step 2. This is a plan gap that blocks step 3 (Agents). Agents T3 waits for it.

The gap: SessionOutbox.stage(event:) makes the MailID of run mail, but the output events runMessage, runSettled, runProgress and elicitationRequested do not carry it. Agents must wait for the delivery of each child message by MailID (mailbox.md section 5, problem 15, "Gap found at the start of step 3").

The decision:
1. SessionOutbox.post(event:) makes the MailID before the journal write. It gives the MailID to the journal write and to stage.
2. Each of these four output events has the origin `.mail([id])` of its run mail. The journal write runs in the journal chain. Bind the origin there explicitly. Do not depend on the task-local value of the poster.
3. A coalesced progress event (a replace of queued progress mail) has the id of the queued mail that it replaces.
4. An event that makes no mail (a stopped run in ignoredRuns, or a refused put after close) has no mail origin. Keep its origin as it is today, and say which origin in the doc.
5. The doc of each of the four SessionEvent cases says that the origin holds the MailID of its run mail.
6. Fixed-order tests with no clock:
   - The origin id of a runMessage equals the id of the later mailDelivered and an id in answered.mailIds.
   - The same for runSettled.
   - A coalesced progress keeps the queued id.
   - A stopped run gives no mail id.
   - Also the order where mailDelivered comes before the runMessage output event, if that order can occur. Tell the reviewer if it can.

Run the full suite one time, commit, and report. When the reviewer accepts it, push it, because Agents builds against Router main.

#mail #mail-step-2