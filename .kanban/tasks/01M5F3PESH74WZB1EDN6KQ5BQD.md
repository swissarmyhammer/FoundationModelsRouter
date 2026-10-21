---
assignees:
- claude-code
depends_on:
- 01M5F3N4646VMYQWK4S17NH345
- 01M5F3K0T51RYV86Y2NXVGFFEC
- 01M5F3KKY94S2A8N8JCBN9FC99
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F43CQ0KR0A2E8FA8CAT9XK
position_column: todo
position_ordinal: '8e80'
title: 'ROUTER-5: Delivery rules (idle starts a turn, working queues, recorded restores, archived refuses, read never starts a turn)'
---
## Goal
`send` follows the delivery rules of ROUTER-5 for each target, and the receipt tells which rule applied.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-5-message-delivery-and-loop-guards (the delivery rules)
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.7
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 10.2 and 13.3; TestudoApp decision D72 (a), (b)

## Blocked on a spec decision (tag needs-decision)
Where a message to a working session waits. The spec says it "waits until the current turn ends" and that a read message never starts a turn. Plan: the directory holds it in its ledger and mails it when the target goes idle, because a mail already in the session's own queue cannot be withdrawn without a `cancelled` record. The other choice is to mail it at once and withdraw it (cancel) on `inbox(markRead:)`. Remove the tag and this section when the spec owner chooses.

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift` and `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionMessageLedger.swift`:
  - **Idle target** (ROUTER-9 state `idle`): mail it now; it starts a turn. Receipt `delivered`.
  - **Working or needsInput target:** the directory holds the message as unread in the ledger and does not mail it yet. Receipt `queued`. When the target's state goes to `idle` (the ROUTER-9 feed), the directory mails all of its unread held messages as one batch, so they start one turn.
  - **Read messages never start a turn:** `inbox(of:markRead: true)` marks the held messages read, and a read message is never mailed later. This is why the directory holds the messages itself: a mail already in the session's own queue (`Session/SessionOutbox.swift`) cannot be withdrawn without a `cancelled` record. If the spec owner prefers withdrawal from the session queue, change this card first.
  - **Recorded target that is not live** (resolver `restoreThenDeliver`): `launcher.restoreSession(id)` (ROUTER-8), register it, then mail the message; it starts a turn. Receipt `delivered`. A restore that throws gives `refused` with the error text. No launcher throws `noLauncher`.
  - **Archived target:** `refused` with the reason "archived" (the resolver already decides it; ROUTER-11 sets the state). The launcher is never called for it.
  - No start and no delivery waits for a free slot: there is no limit on the number of sessions that work at the same time (D72; the model pool controls the load, D7).

## Subtasks
- [ ] Failing test first: a send to an idle session gives `delivered` and the scripted model answers it.
- [ ] Working target: the receipt is `queued`, nothing reaches the session's queue until its turn ends, then the held messages start exactly one turn.
- [ ] `inbox(of:markRead: true)` during the turn: the turn ends and no new turn starts.
- [ ] Recorded target: the fake launcher's `restoreSession` is called once, the session is live, and the message starts a turn; a throwing restore gives `refused`.
- [ ] Archived target: `refused` with "archived", and the fake launcher records no call.

## Acceptance Criteria
- [ ] Idle gives `delivered` and a turn; working and needsInput give `queued` and a turn only after the current turn ends.
- [ ] A message marked read by `inbox` never starts a turn.
- [ ] A recorded session is restored through the launcher and the message starts a turn.
- [ ] An archived target is refused with the reason "archived" and is not restored.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveryTests.swift` (scripted models and `Helpers/FakeSessionLauncher.swift`).
- [ ] `swift test --filter RouterSessionDirectoryDelivery` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #mail #needs-decision