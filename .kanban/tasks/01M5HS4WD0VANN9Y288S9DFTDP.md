---
assignees:
- claude-code
depends_on:
- 01M5HS4C6FBNTAX30161HP0BS5
position_column: todo
position_ordinal: '9880'
title: 'ROUTER: transcript.jsonl goes through Extras JSONLFile; delete sessions.jsonl (SessionIndex) and the JSONL rewrite code'
---
## What
User decisions (2026-10-22):
- JSONL is append-only. Files open in append mode, each write is one full line, and every line is fsynced. One Extras type, `JSONLFile`, is used everywhere.
- `sessions.jsonl` is eliminated. Sessions are listed by listing the recording root's session folders and reading each `index.md` (see the index.md card).
- `projects.jsonl` becomes a folder with one file per project (see the ProjectStore card).

So the only JSONL file Router writes is `transcript.jsonl`.
- `transcript.jsonl` (JSONLRecorder, appendJSONLine, openHandleForAppending) writes and reads through `JSONLFile`, with an fsync per line instead of only when a response finishes.
- Delete `SessionIndex`, `SessionIndexRecord`, `sessions.jsonl`, and the directory's sessions.jsonl writer from ed7b7c27. Recorded listing reads index.md instead.
- Delete `JSONLines.replaceFile`, `JSONLines.appendLine` and the seek-to-end FileHandle appends.
- No backward compatibility.

## Subtasks
- [ ] Move transcript.jsonl onto JSONLFile with an fsync per line
- [ ] Delete SessionIndex and sessions.jsonl, and their tests; update RecordedSessions and the public-surface tests
- [ ] Delete the JSONLines rewrite and append helpers
- [ ] Failing tests first: a transcript append only grows the file, and each line is fsynced
- [ ] `swift test` passes, zero warnings

Depends on the EXTRAS JSONLFile card.