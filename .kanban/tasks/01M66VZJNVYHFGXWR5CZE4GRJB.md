---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m68md96cnep2r0n6xnj4pv9p
  text: |-
    ### implement — changed
    - Source: RouterSessionDirectory.swift. deliver(_:chainDepth:to:) writes an inbox file for a durable session (new writeInboxFile), and keeps the direct path for a memory-only session (new deliverDirectly). restoreThenDeliver writes the file, then restores, and removes the file when the restore throws. removeInboxFile takes the failure text. Doc comments of send(_:), deliver and restoreThenDeliver now describe the ledger lag and the closing-but-registered case.
    - Discovery 1: the restore receipt cannot read deliveryOutcome(of:). The first scan of the watcher can start the turn before restoreThenDeliver goes on, so the state is working and the outcome is queued. The restore path returns delivered by definition.
    - Discovery 2: a test directory that is not the router own directory, with sessions registered in both, has two watchers on one inbox folder. They race for each file, and the loser sends no messageDelivered event. SessionMessageLoopGuardTests fixture now unregisters the session from the router own directory.
    - Tests: 6 new tests in RouterSessionDirectoryInboxTests (live send via file, closing session file waits, ledger after event, memory-only direct, restore writes file first, failed restore removes file). New helper sendAndAwaitDelivery (Helpers/RouterSessionDirectory+SendAndAwaitDelivery.swift), used by DirectorySendTool, DeliveryTests, MessageTests, LoopGuardTests and AgentMessagePromptTextTests. ArchiveTests and NoCapTests needed no change (they send refusals or start agents).
    - Evidence: filters Inbox 24, Delivery 9, Message 21, LoopGuard 6, Archive 11, NoCap 1 all pass; full swift test: 2168 tests in 268 suites passed, no new warnings.
    - next: review
  timestamp: 2026-10-31T09:24:48.460855+00:00
- actor: claude-code
  id: 01m68mprmj2seym2tvt4d7gj0q
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD: 1 finding (RouterSessionDirectoryDeliveryTests.swift:271, duplication). Checked: restore path returns delivered with a doc reason; archiveLive scans before cancelAll with no suspension; LoopGuard fixture unregisters from the router directory; failed restore removes the file; doc comments of send, deliver and restoreThenDeliver match the task; no sleep, retry or time limit in the test diff.
    - next: fix the open finding, then run /review again.
  timestamp: 2026-10-31T09:29:59.186538+00:00
- actor: claude-code
  id: 01m68mq3me006x0nc001yx0a50
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, helper RouterSessionDirectory+SendAndAwaitDelivery.swift, 6 test files
    - test: green — swift test, 2168 tests, 0 failures (archive race fixed in archiveLive)
    - commit: 352168eb
    - review: findings — RouterSessionDirectoryDeliveryTests.swift:271
  timestamp: 2026-10-31T09:30:10.446017+00:00
- actor: claude-code
  id: 01m68ms994xs98f71sskt6j6cn
  text: |-
    ### implement — changed
    - Added shared `sendAndAwaitDelivery(_:fromClient:to:)` to Tests/FoundationModelsRouterTests/Helpers/RouterSessionDirectory+SendAndAwaitDelivery.swift.
    - Used it in DeliveryTests (helper `send` and `aSendToASessionThatNeedsInputIsQueued`) and removed the same copied user-to-session send in RouterSessionDirectoryMessageTests (6 places). The `.tag` call is unchanged.
    - evidence: swift test --filter 'RouterSessionDirectoryDeliveryTests|RouterSessionDirectoryMessageTests': 30 tests in 2 suites passed.
    - next: review
  timestamp: 2026-10-31T09:31:21.764293+00:00
depends_on:
- 01M66VZ885BGD130W6TSSS8B7C
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-10-31 04:27)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveryTests.swift:271` `duplication/duplication` — The `aSendToASessionThatNeedsInputIsQueued` test rebuilds the send that the file's own `send(_:to:in:)` helper already performs: `directory.sendAndAwaitDelivery(OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(id), text: Self.text))`. The copy is inlined because the helper takes a `Fixture` and this test uses a `BackgroundingSessionFixture`. If the helper's sender, target shape, or waiting behavior changes, this copy drifts out of sync. Move the helper's body to a shared function that takes a `RouterSessionDirectory` (or the directory from the fixture) and an id, and call it from both the `Fixture`-based helper and this test. Do not change the `.tag` call at lines 212-213.
