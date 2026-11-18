---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qk32ftrj1thsp5vm5bf9gw
  text: |-
    Research (implement step):
    - Today each delivery path ends in `hand(_:userHeader:to:ledger:)` (direct, inbox scan) or in `startAgent` + `launch`. Both put the mail in the queue (`session.mail`) and then call `keep(_:in:)`, which writes the ledger and sends `messageDelivered` AT ONCE. Thus a message to a working target (receipt `queued`) gives its event at queue time. Card test 3 ("not when it is queued") fails today.
    - `SessionMessage` of each path already has `sourceSession` (`Self.delivered`), also the scan path (^ty244es).
    - Order: the event goes out after `session.mail` returns. The pump of the target is a separate task (`arrival.start { mailDidArrive }`), and `keep` appends a line to `messages.jsonl` before the emit. Thus the first output of the answer can come before the event. No order guarantee today.
    - The session sends `SessionEvent.mailDelivered(id)` when the pump takes the mail; it is the first event of the answer, and each session event goes through one point: `RoutedSessionActor.emitSessionScopedEvent` (also `.cancelled`, `.lost`).
    - Decision: the directory sends `messageDelivered` when the target gets the message: a synchronous observer on the session, called in `emitSessionScopedEvent` before the session event goes to the output hub. The directory keeps each message that waits for its delivery under its registry lock (set before the put, so a fast pump cannot miss it). A `.cancelled`/`.lost` of the mail, or the unregistration of the session, drops it with no event. An `inbox(of:markRead: true)` read of a waiting message is also a delivery to the target (it never starts a turn), so the read sends the event and the take sends none. This matches D199 (f) "a working session gets the message when its turn ends", and the Extras text "the event comes when the target records the message".
    - Effect on tests: `sendAndAwaitDelivery` waited also for `queued` receipts; with the new rule a queued event comes only after the turn ends, so the helper waits only for `delivered` receipts.
  timestamp: 2026-11-18T15:06:03.642200+00:00
- actor: claude-code
  id: 01m7qkkzmdx8pka5st9527y4cr
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsRouter/Session/MailFate.swift`: `MailFate` (delivered / cancelledOrLost) and `RoutedSessionActor.observeMailFate(_:)` / `reportMailFate(of:)`. `emitSessionScopedEvent` calls the observer before the output hub gets the event.
    - `RouterSessionDirectory`: `Registry.awaitingDelivery`; `hand` sets the entry before `session.mail` (a fast pump cannot miss it) and removes it on refusal; `keep` no longer emits; `register` installs the observer; `unregister` and archive forget waiting entries; `inbox(of:markRead: true)` sends the event of a waiting message at the read; `startAgent` now goes through `hand`; `launch` no longer mails.
    - Test helper `sendAndAwaitDelivery` waits for `delivered` and `started` receipts only (a `queued` event comes when the held turn ends). `RouterSessionDirectoryInboxTests` no-watcher test now waits for the event with `nextDelivery(of:)` instead of a marker read right after the send.
    - New suite `RouterSessionDirectoryDeliveredEventTests` (8 tests). RED seen for "gives no event while it waits in the queue". The order test cannot fail deterministically on the old code (the old order was a race), so it passes on both; it is deterministic on the new code.
    - Card test 4 (inbox scan event keeps source session) is already covered by `RouterSessionDirectorySourceSessionTests.theNextOpenKeepsTheSourceSession`.
    - Follow-up note: the Extras doc of `SessionDirectoryEvent.messageDelivered` says "the directory put a message in the queue of the target, and the target recorded it"; it can add "when the target takes it".
  timestamp: 2026-11-18T15:15:17.773386+00:00
- actor: claude-code
  id: 01m7qkmjw5dt0pdvxjyfnhn218
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Session/MailFate.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveredEventTests.swift (new, 8 tests), Tests/FoundationModelsRouterTests/Helpers/RouterSessionDirectory+SendAndAwaitDelivery.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift. Full `swift test`: 2906 tests in 337 suites passed, plus 48 and 19; 0 failures, 0 warnings in the package sources.
    - next: /review
  timestamp: 2026-11-18T15:15:37.477508+00:00
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
- 01M7NQN675DJ1QW9MMPTY244ES
position_column: doing
position_ordinal: '80'
title: Put the source session in the messageDelivered event of each directory message (D199 (f), for ACPA-6)
---
## Goal

The host of the target session can show each delivered directory message in the transcript. FoundationModelsACPAgent uses this for ACPA-6 (`acpa-brief-at-sessions.md`). Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 3. Decision D199 (f).

## Depends on

FoundationModelsExtras task 01M7NQN30QZVJ438F3S3XNX0WV: `SessionMessage.sourceSession`. Extras adds NO new directory event. Use the event that exists: `SessionDirectoryEvent.messageDelivered(SessionMessage)`. `SessionMessage.to` has the target. Do not use `messageDelivered(_, to:)`.

## Current behavior

The Router already sends `messageDelivered` for each delivery (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, doc comments at `:58`, `:997`, `:1021`, `:1154`, `:1223`, `:1332`, `:1353`, `:1400`). The `SessionMessage` in the event has no source session.

## Change

- In the `SessionMessage` of each `messageDelivered` event, set `sourceSession` for a user sender that has a source session. A session sender keeps its sender session as today.
- Make sure that each delivery path sends the event with the correct fields: a direct delivery to a live idle target, a queued delivery when the turn ends, the inbox scan of a recorded target, and a message that starts an agent session.
- Make sure that the event comes before the turn of the message starts, so that the host can show the message before the chunks of its turn. If the order is not correct today, correct it.

## Tests

- [ ] A user message with a source session gives one `messageDelivered` event with the sender `user`, the source session, the target (`to`) and the text.
- [ ] A session message gives one event with the sender session, the target and the text.
- [ ] A queued message gives its event when it is delivered, not when it is queued.
- [ ] A user message from the inbox scan gives its event with the source session.
- [ ] The event comes before the first output of the turn of the message.

#d199