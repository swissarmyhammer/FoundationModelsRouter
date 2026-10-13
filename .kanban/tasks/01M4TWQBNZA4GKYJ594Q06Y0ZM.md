---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'A1-A4: Origin, SessionOutput, MailID and the new terminal events'
---
A1: Add `OriginContext` with `@TaskLocal static var current: Origin = .system`. The pump sets `.mail(ids)` for an answer. A compaction sets `.signal(id)`.
A2: Add `SessionOutput { origin, event }`. `streamSessionEvents()` gives `SessionOutput`. Each send reads `OriginContext.current`.
A3: Change `MessageID` to `MailID` in `SessionAnswer`, `AnswerFailure`, `SubmissionStart` and other public types.
A4: Add `mailDelivered(MailID)`, `cancelled(MailID)`, `lost(MailID)`. Add a test helper that asserts exactly one terminal event for each id.
Commit with build and tests green, then report to swissarmyhammer-96. #mail