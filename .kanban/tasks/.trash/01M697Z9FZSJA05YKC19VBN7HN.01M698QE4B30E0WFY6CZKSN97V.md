---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Restore then deliver: do not strand the file for a restored session with no durable folder'
---
## What
In `RouterSessionDirectory.swift`, `restoreThenDeliver` (about lines 1025-1049) writes the file to `recordedFolder(of:)` before the restore. If the restored session is memory-only (`ledgerDirectory(of:)` is `nil`, because `SessionTreeRestoration.swift:544` passes `routedLLM.durableRecording?.indexWriter`), `register` starts no watcher and the file waits in `inbox/` for ever.

- After the restore, compare `Self.ledgerDirectory(of: session)` with the folder of the file. If they differ, read the file, remove it, and deliver the message on the direct path (`session.mail` and `keep`).
- Keep the removal of the file when the restore throws.

## Acceptance Criteria
- [ ] A restore that gives a memory-only session delivers the message directly and leaves no file in `inbox/`.
- [ ] The durable restore path does not change.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: a launcher that restores a memory-only session.
- [ ] Run `swift test --filter RouterSessionDirectoryInboxTests`. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.