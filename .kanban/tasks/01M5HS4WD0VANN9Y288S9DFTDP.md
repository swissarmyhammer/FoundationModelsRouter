---
assignees:
- claude-code
depends_on:
- 01M5HS4C6FBNTAX30161HP0BS5
position_column: todo
position_ordinal: '9880'
title: 'ROUTER: every JSONL file goes through Extras JSONLFile; sessions.jsonl and projects.jsonl remove by tombstone, never rewrite'
---
## What
User decisions (2026-10-22): JSONL is append-only, opened in append mode, one full line per write, fsync after every line, and one Extras type is used everywhere.
- `transcript.jsonl` (JSONLRecorder, appendJSONLine, openHandleForAppending), `sessions.jsonl` (SessionIndex) and `projects.jsonl` (ProjectRegistry) all write and read through `JSONLFile`.
- The transcript gets an fsync per line, not only at the end of a response.
- **Removal:** `SessionIndex.removeRecords(sessionId:)` appends a tombstone line, and readers fold last line wins. The same goes for each ProjectRegistry update or removal.
- **Rebuild:** `SessionIndex.rebuild(cwd:)` appends lines; it never replaces the file.
- Delete `JSONLines.replaceFile` and the seek-to-end FileHandle appends.
- No backward compatibility.

## Subtasks
- [ ] Move all three files onto JSONLFile
- [ ] Tombstone record for sessions.jsonl and projects.jsonl; readers honour it
- [ ] Failing tests first: removal grows the file and hides the session; earlier bytes are unchanged after any operation
- [ ] Tell ACPAgent and Kanban to move their JSONL writes onto JSONLFile (Kanban EventLog, ACPAgent snapshots)
- [ ] `swift test` passes, zero warnings

Depends on the EXTRAS JSONLFile card. #recording #cross-repo