---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m69dvf5x6wbcmv6mh70yh7m4
  text: |-
    ### implement — changed
    - evidence: SessionInboxFile.swift (two from forms, new error userSenderNotWritten, write refuses non-default user), RouterSessionDirectory.swift (deliver uses deliverDirectly for user senders, ledger folder kept; sendToRecorded refuses user with userNeedsLiveSessionReason; docs), SessionInboxFileTests, RouterSessionDirectoryInboxTests, RouterSessionDirectoryDeliveryTests, SendAndAwaitDelivery helper. Filter run of 7 suites: 104 tests passed.
    - next: test (full suite), review.
  timestamp: 2026-10-31T16:49:27.741552+00:00
depends_on:
- 01M698QM6SE1GFFQTP2XGSG1BP
position_column: doing
position_ordinal: '80'
title: 'Inbox `from` is a session id: drop the user:<clientID> form, send user senders directly'
---
## What
Sessions talk to each other through the inbox, so the `from` of an inbox file is a session id. Remove the `user:<clientID>` form that task ^ypcz0p2 added.

- `Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift`: the `from` key has two forms only: `session:<ULID>`, and plain `user` (the default of a hand-written file, as in `mailbox-plan.md`). Remove `userPrefix`, the `user:<clientID>` read in `SessionMessageSender(inboxText:)`, and the write of it. A value `user:<anything>` is now an `invalidSender` parse failure. Write refuses a `.user(clientID:)` sender other than the plain default (add a typed error) — the Router never writes one. Update the doc comment of the `from` forms.
- `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: `deliver(_:chainDepth:to:)` writes an inbox file only when `message.from` is a session sender. A user sender (`SessionMessageSender.user(clientID:)`, a UI send) to a live session takes the direct path (`session.mail(...)` and `keep(...)`), as a memory-only session does now, and keeps its client id in the ledger. A user sender to a recorded session that is not live (`sendToRecorded`, from task ^xgsg1bp) is refused with the reason "a message from a user needs a live session", because the inbox cannot keep a client id. Update the doc comments of `send(_:)`, `deliver` and `sendToRecorded`.
- Keep one shared delivery function for the direct path; do not copy it.

## Acceptance Criteria
- [ ] A file with `from: user:abc` is rejected as `invalidSender` and moved to `inbox/rejected/`.
- [ ] A file with no `from`, or with `from: user`, is delivered with the default user sender.
- [ ] `send(_:)` from a session to a durable session writes a file with `from: session:<id>`; the ledger keeps the sender.
- [ ] `send(_:)` from a UI sender (`.user(clientID:)`) to a live durable session writes no file, delivers at once, and the ledger and the inbox result keep the client id.
- [ ] `send(_:)` from a UI sender to a recorded session that is not live is `refused` with the reason above and writes no file.

## Tests
- [ ] Update `Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift`: remove the `user:<clientID>` round trip; add the `user:abc` rejection and the write refusal.
- [ ] Update `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: durable send from a session writes a file; durable send from a UI sender writes none; UI sender to a dormant session is refused. Tests that assert a file for a durable send must use a session sender. Wait on events, not on the clock.
- [ ] Run `swift test --filter 'SessionInboxFileTests|RouterSessionDirectoryInboxTests'`, then the full `swift test` once. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.