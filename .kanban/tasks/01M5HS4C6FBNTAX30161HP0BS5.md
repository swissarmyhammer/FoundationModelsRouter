---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j2p1600wxvg052qpvanrv3
  text: 'Picked up; research done. Extras has no JSONL code yet (no O_APPEND/fsync/jsonl anywhere in Sources). Plan: new `Sources/FoundationModelsExtras/JSONLFile.swift` (struct JSONLFile + JSONLFileError + JSONLKeyedRecord protocol for the last-wins fold with tombstones), tests in `Tests/FoundationModelsExtrasTests/JSONLFileTests.swift` (Swift Testing, TemporaryDirectory from FixtureSupport). Torn-tail warning goes through `ExtrasTelemetry.makeLogger()` like BackgroundWork.freedWithNoEndMessage, with a byte-count metadata key added to `ExtrasTelemetry.LogMetadataKey`; the content of the torn line never enters the log (TelemetryCapture forbids it in the test). Concurrent appenders are modelled in the unit test by many concurrent tasks each opening their own O_APPEND descriptor (the same kernel guarantee as two processes).'
  timestamp: 2026-10-22T15:11:43.296605+00:00
- actor: claude-code
  id: 01m5j2w7sk59vef1rsc2n4233d
  text: 'BLOCKER — duplicate concurrent work. Another session is implementing this same card at the same time, in the same FoundationModelsExtras working tree. It works from the Extras-board copy of the card, 01M5J2FHC6XQ4KTF2YM5RW57MJ (^5rw57mj, untracked in Extras/.kanban, in `doing`, with its own research comment at 15:12Z). While I was in the TDD cycle, that session overwrote Tests/FoundationModelsExtrasTests/JSONLFileTests.swift with its own suite (records `Entry(id:value:)`, `Synchronization` import, 16 KiB padding). My edits then stopped matching the file. Two writers on one file would destroy each other''s work. So I withdrew everything I had written: Sources/FoundationModelsExtras/JSONLFile.swift (deleted after checking its sha matched my last write) and the `tornLineBytes` key I had added to ExtrasTelemetry.LogMetadataKey (reverted). I did not touch the other session''s test file. `git status` in Extras now shows only that file and the ^5rw57mj card. What I tried before the overwrite: RED was confirmed (`swift build --build-tests` failed on the missing `JSONLFile`, `JSONLKeyedRecord` and `JSONLFileError`). My design is the same shape as the other session''s plan, so nothing is lost. A person needs to decide which session owns the work: let ^5rw57mj finish and then close or point this Router card at it, or stop that session and run this one again. One more point for whoever finishes: after a crash leaves a torn tail, the next O_APPEND write starts right after the torn bytes. The torn tail then becomes a corrupt earlier line, and every later read throws. The card says never truncate, so the card has to say how a torn tail is healed (or whether a read tolerates it).'
  timestamp: 2026-10-22T15:15:06.675435+00:00
- actor: claude-code
  id: 01m5j2wd3qrvxywewe4am5gha3
  text: |-
    ### implement — stuck
    - evidence: no files changed. Another session is running the same work in FoundationModelsExtras from Extras card 01M5J2FHC6XQ4KTF2YM5RW57MJ (^5rw57mj), and it overwrote Tests/FoundationModelsExtrasTests/JSONLFileTests.swift. I withdrew my Sources/FoundationModelsExtras/JSONLFile.swift and my ExtrasTelemetry key. Extras `git status` shows only the other session's test file and its card.
    - next: a person decides which session owns the JSONLFile work, then closes or re-points this card. Subtasks 0/4 checked.
  timestamp: 2026-10-22T15:15:12.119630+00:00
- actor: wballard
  id: 01m5j2xm9ht7jybgvqxtv65kfd
  text: 'Owned by the Extras session: its card ^5rw57mj (Extras board) is the same work, already in doing. My implementer collided with it in the Extras tree and withdrew. This card closes when Extras lands JSONLFile and Router''s pin is bumped. Torn-tail design gap passed to Extras.'
  timestamp: 2026-10-22T15:15:52.241496+00:00
position_column: doing
position_ordinal: '80'
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