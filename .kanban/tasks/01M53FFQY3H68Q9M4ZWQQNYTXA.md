---
assignees:
- claude-code
depends_on:
- 01M53FFKACCYMAKXPXKK8WKXJ2
position_column: todo
position_ordinal: '8380'
title: 'Group D: paused event on requeue, idle after cancelAll, relay presence guard, end the relay wait on close'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 3, group D. Each fix starts with a test that fails before the fix.

- [ ] (a) `requeueUndeliveredRunMail` (RoutedSessionActorRecording.swift ~213-226) holds run mail and sends no `mailDeliveryPaused` event. Send the event. If there is a correct reason not to send it, record the reason on this card and tell the coordinating session.
- [ ] (b) After `cancelAll()`, a parent P can be idle while its child still works (RoutedSessionActorIdle.swift ~192-195: a settled run R is not in `openRuns`, so the child-works flag has no effect). P sends `workEnded`, then `workStarted` with no new input. Fix it, or record the design reason on this card and tell the coordinating session.
- [ ] (c) `SubagentQuestionRelay.start()` has no presence check, so it starts for a headless target. Add the guard (Agents has the same guard today).
- [ ] (d) `awaitRelayedQuestionRecorded` (RoutedSessionActorRelayedQuestions.swift ~346-348) can wait forever when P finished its close before the relay sends the question up. End the wait on close.
- [ ] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes