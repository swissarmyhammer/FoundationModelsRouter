---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4v70jtw9qyte06zjs4dyrxj
  text: 'Note from the reviewer: requeued run mail gets mailDelivered twice. The transcript and ContextRenderer must render it only once, at its final delivery. Add a test for this.'
  timestamp: 2026-10-13T18:04:51.420125+00:00
- actor: claude-code
  id: 01m4vcpn2ndb2yv5trkwa9k2ha
  text: 'Done in commit d4e5691d. The build is clean. The full suite passed 2 of 2 runs (1655 tests in 205 suites, 2 known issues). The report with 11 differences went to the reviewer. Known gap: a retried attempt gets no mailDelivered record on its retry prompt. If the reviewer does not answer, fix it at the start of part E.'
  timestamp: 2026-10-13T19:44:17.493864+00:00
position_column: done
position_ordinal: ffffffd880
title: 'D1-D4: Transcript entries, ContextRenderer and restore'
---
D1: Custom segments `mailQueued`, `mailDelivered` (rendered), `cancelled`, `replaced`.
D2: `ContextRenderer`: a pure function from the transcript to the context. It starts at the last compacted value. Run mail is rendered at delivery.
D3: Raise `RecordingSchemaVersion`.
D4: At restore, each mail with no terminal event gets one `lost` event. A restart does not run tool side effects again.
Commit with build and tests green, then report. #mail