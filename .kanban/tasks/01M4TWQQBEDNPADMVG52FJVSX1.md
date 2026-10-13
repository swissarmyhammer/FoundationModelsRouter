---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4veyes1rzvf91a2h01k0bwn
  text: 'Done in commit ee71f54e, which includes the fix for the retry gap from part D. The build is clean. The full suite passed 2 of 2 runs (1664 tests in 205 suites, 2 known issues). The rename of mailbox to runPlane is complete (the part F item 1 is done). The report went to the reviewer. A latent part D problem is open: the records of a failed attempt with no recovery can go on an older prompt. Fix it at the start of part F.'
  timestamp: 2026-10-13T20:23:30.337617+00:00
position_column: done
position_ordinal: ffffffd980
title: 'E1-E3: Telemetry and names'
---
E1: `recordMessageQueueDepth()` becomes `recordMailQueueDepth()` with the dimension `mail.kind`.
E2: `submission.cause` keeps its raw values; add `submission.mail_ids`. Add `compaction.reason` and `signal.id`. Add the metrics `mail_queue.pause_duration` and `mail.cancelled`.
E3: Rename `mailbox` to `runPlane` (also `childMailbox` and `SessionPlumbingAccess`). Rename `SessionProjection` to `SessionObserver` with a deprecated typealias.
Commit with build and tests green, then report. #mail