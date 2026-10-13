---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'D1-D4: Transcript entries, ContextRenderer and restore'
---
D1: Custom segments `mailQueued`, `mailDelivered` (rendered), `cancelled`, `replaced`.
D2: `ContextRenderer`: a pure function from the transcript to the context. It starts at the last compacted value. Run mail is rendered at delivery.
D3: Raise `RecordingSchemaVersion`.
D4: At restore, each mail with no terminal event gets one `lost` event. A restart does not run tool side effects again.
Commit with build and tests green, then report. #mail