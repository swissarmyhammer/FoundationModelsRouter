---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Durable send: deliver the file at once when the session has no inbox watcher'
---
## What
In `RouterSessionDirectory.swift`, `openInboxWatcher(of:)` logs an error and the session then runs with no watcher. Since `deliver(_:chainDepth:to:)` only writes a file, a send to such a session is never delivered, and the receipt still says `delivered` or `queued`. The doc comment of `openInboxWatcher(of:)` ("a send still delivers") is false now.

- Record in the registry `Entry` that the session has no watcher.
- In `deliver(_:chainDepth:to:)`, call `scanInbox(of: id)` right after `writeInboxFile` when the session has no watcher.
- Correct the doc comment.

## Acceptance Criteria
- [ ] A send to a durable session with no watcher is delivered (the ledger holds the message, the file is gone).
- [ ] A session with a watcher does not scan in `deliver`.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: make the inbox folder fail to open (for example, a regular file in the place of `inbox/`), send, and expect delivery.
- [ ] Run `swift test --filter RouterSessionDirectoryInboxTests`. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.