---
assignees:
- claude-code
depends_on:
- 01M66VYQ268GZBRG3RDYPCZ0P2
position_column: todo
position_ordinal: '8180'
title: Deliver inbox files in RouterSessionDirectory (scan, idempotent, reject)
---
## What
In `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, add an inbox scan for one live durable session. Do not add the watcher here (next task).

- New actor method `scanInbox(of id: ULID)`. It is synchronous on the actor, with no suspension point between the ledger check and `keep`, so two scans cannot deliver one file two times (actor reentrancy). List `SessionInboxFile.pending(in:)` (sorted by name). For each file:
  1. Parse with `limits.maxMessageBytes`. On a parse failure, `reject` the file and log the error with `RouterTelemetry.makeLogger(.sessionDirectory)`. Do not delete it.
  2. If `ledger(of:in:)` already holds the `id` (`SessionMessageLedger.message(_:)`), remove the file and continue. This makes delivery idempotent after a crash.
  3. Else run the present body of `deliver(_:chainDepth:to:)`: `session.mail(mail(id:carrying:from:inReplyTo:))`, `keep(_:in:)` with the `chainDepth` of the file, and `messageDelivered`. Build the sender header from the live summary of the sender, as now.
  4. Remove the file.
- Error rule (the scan has no caller): a `MailRefusal.closed`, a ledger read error, or another mail refusal is logged, the file stays in `inbox/`, and the scan for that session stops.
- Share the delivery code with the present `deliver`; do not copy it.
- Decision: remove the file after delivery (no `inbox/delivered/`).

## Acceptance Criteria
- [ ] A file in `inbox/` of a live idle durable session starts a turn after `scanInbox`, the ledger holds the message with the `chainDepth` of the file, and the file is gone.
- [ ] A file for a working session waits in the mail queue until the turn ends.
- [ ] A file whose `id` is in the ledger is removed and not delivered again.
- [ ] Two scans on the same file deliver it one time.
- [ ] A file that does not parse is moved to `inbox/rejected/`.
- [ ] A closed session leaves the file in `inbox/`; a ledger read error leaves it too.
- [ ] Unknown frontmatter keys do not stop delivery.
- [ ] The `chainDepth` from the file reaches the ledger, and the loop guard reads it on the next send.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift` (use the fixture of `RouterSessionDirectoryDeliveryTests.swift`): idle delivery, working session queue, duplicate id, two scans, bad file, closed session, chainDepth and the loop guard.
- [ ] Run `swift test --filter RouterSessionDirectoryInboxTests`. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.