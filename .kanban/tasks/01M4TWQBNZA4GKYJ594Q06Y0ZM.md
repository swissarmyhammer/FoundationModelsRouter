---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4v70fk2j5ytd3ghy3zm85wf
  text: Done in commit ce6c07bd. 1585 tests pass. Reviewer accepted, with the rename messageIds -> mailIds and mailQueueDepth() added early.
  timestamp: 2026-10-13T18:04:48.098566+00:00
position_column: done
position_ordinal: ffffffd580
title: 'A1-A4: Origin, SessionOutput, MailID and the new terminal events'
---
A1: Add `OriginContext` with `@TaskLocal static var current: Origin = .system`. The pump sets `.mail(ids)` for an answer. A compaction sets `.signal(id)`.
A2: Add `SessionOutput { origin, event }`. `streamSessionEvents()` gives `SessionOutput`. Each send reads `OriginContext.current`.
A3: Change `MessageID` to `MailID` in `SessionAnswer`, `AnswerFailure`, `SubmissionStart` and other public types.
A4: Add `mailDelivered(MailID)`, `cancelled(MailID)`, `lost(MailID)`. Add a test helper that asserts exactly one terminal event for each id.
Commit with build and tests green, then report to swissarmyhammer-96. #mail