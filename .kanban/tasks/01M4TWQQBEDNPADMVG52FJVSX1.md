---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'E1-E3: Telemetry and names'
---
E1: `recordMessageQueueDepth()` becomes `recordMailQueueDepth()` with the dimension `mail.kind`.
E2: `submission.cause` keeps its raw values; add `submission.mail_ids`. Add `compaction.reason` and `signal.id`. Add the metrics `mail_queue.pause_duration` and `mail.cancelled`.
E3: Rename `mailbox` to `runPlane` (also `childMailbox` and `SessionPlumbingAccess`). Rename `SessionProjection` to `SessionObserver` with a deprecated typealias.
Commit with build and tests green, then report. #mail