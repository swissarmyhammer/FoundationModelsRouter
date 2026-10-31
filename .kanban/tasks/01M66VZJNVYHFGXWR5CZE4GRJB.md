---
assignees:
- claude-code
depends_on:
- 01M66VZ885BGD130W6TSSS8B7C
position_column: todo
position_ordinal: '8380'
title: Route send(_:) to a durable session through an inbox file
---
## What
In `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, change `deliver(_:chainDepth:to:)` (about line 806) and `restoreThenDeliver` (about line 863).

- Durable session (`ledgerDirectory(of:)` not `nil`): write an inbox file with `SessionInboxFile.write` (`id`, `from`, `inReplyTo`, `chainDepth`) in place of `session.mail(...)`. Do not call `keep(...)` here; the scan records the message. The receipt carries the file `id` as `messageID`, and its outcome comes from `deliveryOutcome(of:)`, as now.
- Memory-only session: keep the direct path (`session.mail(...)` and `keep`). It writes no file.
- `restoreThenDeliver`: write the file, then restore. The restore registers the session, the watcher starts, and its first scan delivers the message. Keep the `register` fallback for a session from another router. If the restore throws, remove the file, so a message that got a `refused` receipt is not delivered later.
- `startAgent`: no change.
- `send(_:)`, address resolution, loop guards, `inbox(of:markRead:)` and `withdrawWaitingMail`: no change.
- Update the doc comments of `send(_:)` and `deliver`: (1) a durable message goes through the inbox file and the ledger is written at the scan, so `inbox(of:markRead:)` and `withdrawWaitingMail` can miss the receipt `messageID` for a short time; (2) a session that is closing but still registered gives `delivered`, and the file waits for the next open (the old `refused` / not-live receipt is gone for that case).
- Do not change the FoundationModelsMultitool `sessions` tool.

## Acceptance Criteria
- [ ] `send(_:)` to a live durable session writes a file and does not call `session.mail(...)` itself; the watcher delivers it and the receipt outcome is `delivered` (idle) or `queued` (working).
- [ ] A `.user(clientID:)` sender survives the file: the ledger message and the inbox result keep the client id.
- [ ] `send(_:)` to a memory-only session calls `session.mail(...)` and writes no file.
- [ ] `send(_:)` to a recorded session that is not live restores it and the message is delivered at restore.
- [ ] A restore that throws leaves no file in `inbox/`.
- [ ] A test shows the documented lag: the `messageID` of the receipt is in the ledger after the delivery event.
- [ ] Existing tests of send, tag, archive and restore stay green.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: durable send writes a file, memory-only send writes none, restore-then-deliver, failed restore removes the file, chainDepth through `send` reaches the ledger and the next send reads it, the lag.
- [ ] Update the tests that assume the ledger holds the message when `send` returns (wait for the delivery event; no sleep): `RouterSessionDirectoryDeliveryTests.swift`, `RouterSessionDirectoryMessageTests.swift`, `RouterSessionDirectoryArchiveTests.swift`, `SessionMessageLoopGuardTests.swift`, `RouterSessionDirectoryNoCapTests.swift`, and `Tests/FoundationModelsRouterTests/Helpers/DirectorySendTool.swift`.
- [ ] Run the full suite once: `swift test`. Expected: all pass, no new warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.