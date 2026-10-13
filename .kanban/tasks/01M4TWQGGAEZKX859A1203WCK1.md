---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4v70gq27aqnvbvgek739prf
  text: 'Done in commit 4976f211. 1635 tests pass. Reviewer accepted. User changes in scope: cancelAll() and drain merge into one signal; signals run in order and return SignalID with signalDone; cancelAll does not wait for slow run cancelers.'
  timestamp: 2026-10-13T18:04:49.250578+00:00
position_column: done
position_ordinal: ffffffd680
title: 'B1-B7: MailQueue, mail(_:), signals and helpers'
---
B1: One Extras `MailQueue` replaces `SessionOutbox.messages` and `SessionOutbox.events`. Remove the delivery letter and the cancel marks.
B2: The pump uses `waitForMail()` and `take(admitting:)`. Keep each run-mail rule (coalesce, canStartASubmission, held mail, requeue, putBack, withdrawStagedEvents). Send `mailDelivered` at take.
B3: `RoutedSession` conforms to `MailSink` with `Event = SessionOutput`. Refuse duplicate ids in the queue and in the open answer. A guided session never sends `textDelta`.
B4: Signals `cancel(id)`, `cancelAll()`, `replace(id, with:)`. `drain` and `close` send `cancelled`. Remove `cancel()` and `cancel(message:)`.
B5: Helpers `respond(to:)`, `streamEvents(to:)`, `streamResponse(to:)`, `send(_:)`, `pendingMessages()`, `mailQueueDepth()`, and one "wait for the terminal event" helper. Keep the wait guard.
B6: `respond(elicitationId:response:)` also posts `elicitationAnswer` mail.
B7: Remove the typealiases in `Session/MessageQueue.swift` and each Router use of `Mailbox` and the `MessageQueue` types.
Commit with build and tests green, then report. #mail