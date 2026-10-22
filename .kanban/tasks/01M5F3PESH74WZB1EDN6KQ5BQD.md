---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f65znp1zzma4sgnpngbns1
  text: |-
    ### decision — user (2026-10-21)
    - A message to a working session goes straight into the session's own mail queue. The directory does not hold it. Accepted trade-off: once a message is queued it can't be withdrawn cleanly. If inbox(markRead:) reads it before delivery, the transcript keeps a "cancelled" record, or the message is delivered anyway. Pick whichever the existing mail queue already supports, and document it.
  timestamp: 2026-10-21T12:15:08.470839+00:00
- actor: claude-code
  id: 01m5j72khvs34tvhbfd5w8g75e
  text: |-
    ### research — picked up
    - The user decision (comment of 2026-10-21) replaces the "directory holds the message" plan on the description: a message to a working or needsInput target goes straight into the session's own mail queue; the receipt is `queued`. The session's pump carries every queued user-type mail in one submission (SessionMailQueueTests: "second" + messageSeparator + "third"), so held messages start one turn.
    - The existing mail queue supports withdrawal: `RoutedSession.cancel(_:)` removes a queued mail and sends `cancelled` (the transcript keeps the cancel record). So `inbox(of:markRead: true)` cancels each marked message whose mail still waits in the queue (`pendingMessages()`). A mail the pump took before the cancel is delivered anyway; that is documented.
    - The receipt rule reads the ROUTER-9 tracked state of the entry (`SessionStateTracking`). The tracking follows the session's event feed asynchronously, so two sends in quick succession can both read `idle` before the first `workStarted` reaches the tracking; the mail still waits in the queue either way.
    - Restore: `launcher.restoreSession(id:)`; a session from this router registers itself at restore (RouterSessionDirectoryForkRestoreTests). A session from another router is registered with the kind and parent of its recorded summary.
    - Archived: the resolver already refuses a summary whose state is `archived`. A recorded summary is archived when `facts.json` holds `archivedAt` (RecordedSessions); a live one only when `SessionStateTracking.archive()` ran, and nothing calls that yet. No new persistence is needed.
    - Existing tests that change: RouterSessionDirectoryMessageTests `aRecordedSessionThatIsNotLiveIsRefusedAsNotLive` and `aClosedSessionIsRefusedAsNotLive` both now take the restore path (a closed session leaves the live list and is recorded). FakeSessionLauncher.restoreSession throws today; it must restore and record calls.
  timestamp: 2026-10-22T16:28:29.627266+00:00
- actor: claude-code
  id: 01m5j7qamkhyyvd84rahegvxp0
  text: |-
    ### implementation landed
    - RED: 6 of the 9 new tests failed for the missing feature (working/needsInput gave `delivered`; the recorded target was refused "not live"; noLauncher was not thrown; the read message started a second turn). 3 passed at once because the behavior already existed: idle `delivered`, the 5-session tag send with no slot limit, and the archived refusal (the resolver already refuses `archivedAt` in facts.json).
    - First RED run exposed a test race, not a product bug: the `stateChanged` working event comes from the mail lease, before the held model call takes its prompt, so later mail could join the first prompt. `startHeldTurn` now also waits on `backend.changes` for the first call.
    - The inbox test syncs on the session's signal order (a probe `cancel(MailID())` and its terminal) instead of awaiting the cancelled mail, so RED fails cleanly instead of hanging.
    - The production inbox does not await the cancel signal: `awaitTerminal(of: SignalID)` throws `waitInsideOpenSubmission` when called in band from a tool of a submission on the same model, which is exactly how the `sessions` tool reads an inbox. The cancel is sent and the trade-off is documented.
    - A concurrent second send to a recorded session joins the restore that runs (`restores` map), so the launcher never makes two live sessions with one id.
    - Removed the two MessageTests that asserted the old "not live" refusal of a recorded or closed session; the delivery suite covers the restore path.
    - The card description now records the decision and the gap for ^4vjph7b (live archived state).
  timestamp: 2026-10-22T16:39:48.627267+00:00
- actor: claude-code
  id: 01m5j7qkstqncaedx56j3s0xzb
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveryTests.swift (new, 9 tests), Tests/FoundationModelsRouterTests/Helpers/FakeSessionLauncher.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryMessageTests.swift (2 obsolete tests removed). `swift build --build-tests` clean; `swift test --filter RouterSessionDirectoryDelivery` 9/9 passed; full `swift test` 2131 tests in 261 suites passed (9 known issues, all pre-existing `withKnownIssue` tests), plus 38 and 19 in the other targets.
    - next: /review
  timestamp: 2026-10-22T16:39:58.010161+00:00
depends_on:
- 01M5F3N4646VMYQWK4S17NH345
- 01M5F3K0T51RYV86Y2NXVGFFEC
- 01M5F3KKY94S2A8N8JCBN9FC99
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F43CQ0KR0A2E8FA8CAT9XK
position_column: doing
position_ordinal: '8180'
title: 'ROUTER-5: Delivery rules (idle starts a turn, working queues, recorded restores, archived refuses, read never starts a turn)'
---
## Goal
`send` follows the delivery rules of ROUTER-5 for each target, and the receipt tells which rule applied.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-5-message-delivery-and-loop-guards (the delivery rules)
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.7
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 10.2 and 13.3; TestudoApp decision D72 (a), (b)

## Decision (user, 2026-10-21)
A message to a working session goes straight into the session's own mail queue; the directory does not hold it. The existing mail queue supports withdrawal (`RoutedSession.cancel(_:)`, terminal event `cancelled`, a cancel record in the transcript), so `inbox(of:markRead: true)` cancels the mail that still waits. A mail the pump took before the cancel runs is delivered anyway (documented on `inbox(of:markRead:)`).

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`:
  - **Idle target** (ROUTER-9 state `idle`): mail it now; it starts a turn. Receipt `delivered`.
  - **Working or needsInput target:** mail it now into the session's own queue, where it waits for the end of the turn. Receipt `queued`. The session's pump carries every waiting message in one turn.
  - **Read messages never start a turn:** `inbox(of:markRead: true)` marks the messages read and cancels the mail of each one that still waits in the session's queue.
  - **Recorded target that is not live** (resolver `restoreThenDeliver`): `launcher.restoreSession(id: id)` (ROUTER-8), register it, then mail the message; it starts a turn. Receipt `delivered`. A restore that throws gives `refused` with the error text. No launcher throws `noLauncher`.
  - **Archived target:** `refused` with the reason "archived" (the resolver already decides it; ROUTER-11 sets the state). The launcher is never called for it.
  - No start and no delivery waits for a free slot: there is no limit on the number of sessions that work at the same time (D72; the model pool controls the load, D7).

## Subtasks
- [x] Failing test first: a send to an idle session gives `delivered` and the scripted model answers it.
- [x] Working target: the receipt is `queued`, the mail waits in the session's queue and reaches no model call until its turn ends, then the waiting messages start exactly one turn (per the decision above, the mail is in the session's queue at once).
- [x] `inbox(of:markRead: true)` during the turn: the turn ends and no new turn starts.
- [x] Recorded target: the fake launcher's `restoreSession` is called once, the session is live, and the message starts a turn; a throwing restore gives `refused`.
- [x] Archived target: `refused` with "archived", and the fake launcher records no call.

## Acceptance Criteria
- [x] Idle gives `delivered` and a turn; working and needsInput give `queued` and a turn only after the current turn ends.
- [x] A message marked read by `inbox` never starts a turn (a mail the pump took before the cancel runs is delivered anyway: the accepted trade-off).
- [x] A recorded session is restored through the launcher and the message starts a turn.
- [x] An archived target is refused with the reason "archived" and is not restored.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveryTests.swift` (scripted models and `Helpers/FakeSessionLauncher.swift`).
- [x] `swift test --filter RouterSessionDirectoryDelivery` passes; the full `swift test` stays green.

## Gap for ^4vjph7b (archive)
The archived refusal reads the archived state that exists today: a recorded session is archived when its `facts.json` holds `archivedAt` (RecordedSessions), and a live session only when `SessionStateTracking.archive()` ran, which nothing calls yet. A live session whose facts hold `archivedAt` still reports its tracked state, so a send to it is delivered. ^4vjph7b's `archive(_:by:)` must call the tracking's `archive()` and take the session off the live list, and move `archivedAt` onto index.md (^2cqepsd), so the refusal covers each archived session.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #mail