---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qmha1afpgzwkn8r8054wdg
  text: |-
    Extras decision (foundationmodelsextras-9e): a new case `SessionDirectoryEvent.messageQueued(SessionMessage)`, Extras task 01M7QMGTGYYBZ80QWHK54DPM0P. Not factsChanged (SessionSummary has no unread count).
    Rule: a send with the receipt `queued` (working target, ledger) or `sent` (recorded target, inbox) gives `messageQueued` at the send. `messageDelivered` comes later, when the target takes the message. A `delivered` receipt (idle target) gives no `messageQueued`, only `messageDelivered`; this replaces test item 3. A `started` receipt (agent start) also gives no `messageQueued`.
    Also: add the new case to each exhaustive `switch` on `SessionDirectoryEvent` in Sources and Tests.
  timestamp: 2026-11-18T15:31:18.698728+00:00
- actor: claude-code
  id: 01m7qpv1qn9a1dj6n7jw58qf22
  text: |-
    Research: Extras 951149c has `SessionDirectoryEvent.messageQueued`. No exhaustive `switch` on `SessionDirectoryEvent` exists in Router Sources or Tests (the build had no errors), so no switch needed the new case. The sends that give a `queued` or `sent` receipt are: `deliver` (inbox-file path of a session sender to a live durable target, outcome from `deliveryOutcome`), `deliverDirectly` (UI sender or memory-only target, through `hand`) and `sendToRecorded` (`sent`). `startAgent` gives `started` and the inbox scan gives no receipt, so they send no `messageQueued`.
    Implementation: (1) `Registry.awaitingQueuedEvent` + `sendQueued(_:)`. `hand(...isQueued:)` puts the message there before the mail put, and sends `messageQueued` after `keep` (ledger write). A refused mail removes it with no event (`apply(.cancelledOrLost)`). When the pump takes the mail before the send sends the event, `Registry.sendDelivered` sends `messageQueued` first, so the order is always queued then delivered. `forgetDeliveries` does not touch the map, because the send always removes its entry. (2) `writeInboxFile` returns the `SessionInboxMessage`. `deliver` (outcome `.queued`) and `sendToRecorded` call the new `sendQueued(_:to:)` after the write, before the scan and before the receipt. The `sentAt` of the queued event is the time of the send; the scan gives the delivered message the time of the scan (same id).
    Tests: new `RouterSessionDirectoryQueuedEventTests` (8 tests). Order is checked with marker events that the test emits after the send returns, and a held turn latch. Idle target order: one `messageDelivered`, no `messageQueued` (rule of the comment, replaces test item 3). 4 tests failed before the change (RED) and pass after.
  timestamp: 2026-11-18T16:11:35.029057+00:00
- actor: claude-code
  id: 01m7qpvd5qgbk4fr26w3rhd1x6
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryQueuedEventTests.swift (new, 8 tests). `swift test --filter FoundationModelsRouterTests.RouterSessionDirectoryQueuedEventTests`: 8 passed (4 failed before the change). Full `swift test`: 2914 tests in 338 suites passed, 48 in 26 passed, 19 in 3 passed; 0 issues; no source warnings.
    - next: review. Not committed; the push and the sha message to foundationmodelsmultitool-89 and testudoapp-9a come after commit.
  timestamp: 2026-11-18T16:11:46.743976+00:00
- actor: claude-code
  id: 01m7qq3k9e755zmrkxvrm2cnhs
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (689aa763): engine 0 findings, 2 refuted. The caller asked for a check of the receipt paths and the order tests, and that check gives 2 findings: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:204 (a `cancelledOrLost` fate during the send removes the `awaitingQueuedEvent` entry, so a `queued` receipt can give no `messageQueued`), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:227 (no test fails when the `sendQueued(id)` call in `sendDelivered` is removed). The receipt paths `deliver` (inbox, `.queued`), `deliverDirectly` (through `hand`, `isQueued`) and `sendToRecorded` (`.sent`) each send `messageQueued`. `startAgent` and the inbox scan correctly send none.
    - next: implement the 2 items in the 2026-11-18 10:12 `## Review Findings` section, then review again.
  timestamp: 2026-11-18T16:16:15.150659+00:00
- actor: claude-code
  id: 01m7qq4306ba5pw0tfff41hc61
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, RouterSessionDirectoryQueuedEventTests.swift (new, 8 tests)
    - test: green — swift test in the implement step, 2914 tests in 338 suites (+48, +19), 0 issues
    - commit: 689aa763
    - review: findings — RouterSessionDirectory.swift:204 (a cancelled or lost fate drops messageQueued), RouterSessionDirectory.swift:227 (no test covers the take before messageQueued)
  timestamp: 2026-11-18T16:16:31.238178+00:00
- actor: claude-code
  id: 01m7qqk2xxqjnbeefwkx3sfwf9
  text: 'Fix of the 2026-11-18 10:12 findings. (1) New `Registry.forgetRefusedMail(_:)` removes the message from `awaitingDelivery` and `awaitingQueuedEvent` with no event. The refused-mail `catch` of `hand` calls it (before: `apply(.cancelledOrLost)`). `apply(.cancelledOrLost)` now removes only the `awaitingDelivery` entry, so a cancel or a loss that the target reports after the put still lets `hand` send `messageQueued`. `hand` is the only place that can end a send with no `queued` receipt after the put (`deliverDirectly` maps `MailRefusal.closed` to `refused`, and other errors throw), so only this `catch` removes the entry. Doc comments of `awaitingQueuedEvent`, `apply`, `forgetDeliveries` and `hand` are correct now. (2) 3 new deterministic Registry tests in `RouterSessionDirectoryQueuedEventTests` with a new registry and one fanout stream: take before the queued event (`sendDelivered` then `sendQueued` gives queued, delivered), `cancelledOrLost` during the send (gives one queued), refused mail (gives no event). The existing feed helper and the new one share `messageEvent(of:)`.'
  timestamp: 2026-11-18T16:24:42.685487+00:00
- actor: claude-code
  id: 01m7qqk69n00mz4j3r15fjr9fz
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryQueuedEventTests.swift (+3 tests). RED: the `cancelledOrLost` test failed with the old `apply` (1 issue of 11 tests). Each test was shown to fail: removal of `sendQueued(id)` from `sendDelivered` failed the order test; removal of the `awaitingQueuedEvent` line from `forgetRefusedMail` failed the refused-mail test; both reverted. `swift test --filter FoundationModelsRouterTests.RouterSessionDirectoryQueuedEventTests`: 11 tests passed. Full `swift test`: 2917 tests in 338 suites passed, 48 in 26 passed, 19 in 3 passed; 0 failures; no warning other than the known mlx-swift_Cmlx bundle note.
    - next: review. Not committed.
  timestamp: 2026-11-18T16:24:46.133786+00:00
position_column: doing
position_ordinal: '80'
title: Send a directory event when a message goes into the ledger or the inbox before delivery (D199 follow-up)
---
## Goal

Multitool shows `unreadCount` of a session. Since 709d82c5 (^jf3j3v5), `messageDelivered` comes only when the target takes the message. Thus no directory event comes when a message goes into the ledger of a working target, or into the inbox file of a recorded target. `unreadCount` changes, but the change feed has no entry until the turn or the next open. Request from TestudoApp (testudoapp-9a), found by Multitool.

## Depends on

FoundationModelsExtras: an event for this case. TestudoApp asked Extras for it: an existing case (for example `factsChanged`) if it fits, else a new case. Do not start before Extras sends the sha. Then update the Extras pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo).

## Current behavior

`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`:
- `hand(` (~:1560) puts the message on `awaitingDelivery` (~:1606) and writes the ledger (`ledger.record(delivered)`, ~:1734) before the target takes it. No event comes at that time.
- `writeInboxFile(` (~:1525) writes the inbox file of a recorded target. No event comes until a host opens the target.

## Change

- Send the Extras event at each place that writes the ledger or an inbox file for a message that is not delivered yet: a queued message of a working target, and a stored message of a recorded target.
- Find all such places (grep `ledger.record` and `writeInboxFile`). Do not miss one.
- Do not change `messageDelivered`: it still comes one time, when the target takes the message.

## Tests

- [x] A message to a working target gives the new event at the send, and `messageDelivered` only when its turn starts.
- [x] A message to a recorded target gives the new event at the send, and no `messageDelivered` until a host opens the target.
- [x] A message to an idle target gives the correct events (the new event if the ledger write comes before the take, and one `messageDelivered`). Write down the order that the test expects.
- [x] A refused message gives no event.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d199

## Review Findings (2026-11-18 10:12)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 6 not reviewed. The engine gave 0 findings (2 refuted). The 2 items below come from the check that the caller asked for: each path with a `queued` or `sent` receipt sends exactly one `messageQueued`, and the order tests can fail.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:204` `task/messageQueued-rule` — `Registry.apply(.cancelledOrLost)` removes the entry from `awaitingQueuedEvent`, and the session calls `apply` from its own fate report (`sessionDidReport`, through `observeMailFate`), not only from the refused-mail `catch` in `hand`. When the target cancels or loses the mail after the put succeeds and before `hand` calls `sendQueued(delivered.id)` (for example, a close or a cancel of the target during the send), the send keeps the message in the ledger and returns a `queued` receipt, but no `messageQueued` goes out. This breaks the rule "a `queued` receipt gives `messageQueued` at the send". The doc of `forgetDeliveries` ("the `messageQueued` event of a `queued` receipt goes out also when the target closes during the send") and of `awaitingQueuedEvent` ("A refused mail removes the message with no event") also do not agree with this path. Remove the entry only in the refused-mail `catch` of `hand`, and let `apply(.cancelledOrLost)` leave `awaitingQueuedEvent` alone, so that each `queued` receipt gives exactly one `messageQueued`. Correct the two doc comments to match.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:227` `task/order-tests-can-fail` — No test fails when the `sendQueued(id)` call in `Registry.sendDelivered` is removed. The held-turn tests stop the pump before `marker`, and the idle and started tests use `isQueued: false`, so no test reaches the path where the pump takes the mail before `hand` sends `messageQueued`. Without that call, this path gives `messageDelivered` before `messageQueued`. `Registry` is internal, so add a deterministic test in `RouterSessionDirectoryQueuedEventTests.swift` that puts one message in both `awaitingQueuedEvent` and `awaitingDelivery`, calls `sendDelivered`, and expects the fanout order `messageQueued` then `messageDelivered`, and then expects no second `messageQueued` from `sendQueued`. Also add a test for the fate path of the first item: a `cancelledOrLost` fate between the put and `sendQueued` still gives one `messageQueued`.