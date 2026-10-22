---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: 'EXTRAS: JSONLFile — the one append-only JSONL writer and reader (append mode, one full line per write, fsync per line)'
---
## What
Add a `JSONLFile` type to FoundationModelsExtras. It is the only way any of our packages writes or reads a `.jsonl` file. User decisions (2026-10-22):
- **Append-only:** open with `O_APPEND | O_CREAT`. Never truncate, rewrite or replace the file, and never seek.
- **One full line per write:** each record is encoded, gets its `\n`, and goes out in a single `write(2)`. No buffering in our code.
- **Flush:** `fsync` after every line, before the append returns.
- **Read:** decode line by line. A torn final line, the expected crash artifact, is dropped with a warning. A corrupt earlier line is an error.
- **Last line wins:** a helper folds the records by key so the newest line for a key wins, and a tombstone record removes the key. Removal is always an appended tombstone line, never a rewrite.
- Keep concurrent appenders from two processes (Router and ACPAgent on sessions.jsonl) whole: one `O_APPEND` write per line.

No backward compatibility (ARCHITECTURE.md).

## Subtasks
- [ ] `JSONLFile` with `append(_:)` (Encodable), `records(as:)` and the last-wins fold with tombstones
- [ ] Failing tests first: append-only on disk (file only grows, earlier bytes unchanged); one line per append; torn tail dropped; corrupt middle line throws; tombstone removes a key; two concurrent appenders produce whole lines
- [ ] Document the rule in the type doc
- [ ] `swift test` passes, zero warnings #cross-repo #recording