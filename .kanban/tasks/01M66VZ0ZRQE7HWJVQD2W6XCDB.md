---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m68h41me6tz5b3q4ahgtqr5k
  text: |-
    ### implement — changed
    - RouterSessionDirectory.swift: new `scanInbox(of:)` (sync on the actor, no suspension point between the ledger check and `keep`). New private `hand(_:to:ledger:)` holds the shared step (mail + keep); `deliver(_:chainDepth:to:)` now calls it. Helpers: `deliverInboxFile`, `rejectInboxFile`, `removeInboxFile`, `logInboxFailure`, static `delivered(_ SessionInboxMessage, to:)` (reuses the existing `delivered` builder).
    - Tests: new RouterSessionDirectoryInboxTests.swift (10 tests). Test helpers `makeFixture`, `startHeldTurn`, `pendingIDs`, `Backend` (DeliveryTests) and `makeFixture` (LoopGuardTests) changed from private to internal for reuse.
    - Note: `close()` unregisters the session before the mail queue closes, so the closed-session test hits the "not live" early return. The `MailRefusal.closed` path of `hand` is handled by the generic catch (log, file stays, scan stops) but no test reaches it with a stub session.
    - evidence: `swift test --filter RouterSessionDirectoryInboxTests` 10/10 pass; neighbours (DeliveryTests, SessionMessageLoopGuardTests, RouterSessionDirectoryMessageTests, SessionInboxFile tests) 64 tests pass.
  timestamp: 2026-10-31T08:27:20.078183+00:00
- actor: claude-code
  id: 01m68ha50detdfbq8er7047dwa
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD. Engine: 0 findings. 1 finding from the known-gap check: RouterSessionDirectoryInboxTests.swift aClosedSessionLeavesTheFile does not reach the mail-refusal path (log, keep file, stop scan) of hand/deliverInboxFile.
    - next: implementer adds a test with a stub session whose mail throws MailRefusal.closed, and corrects the doc comment of the closed-session test. Task stays in review.
  timestamp: 2026-10-31T08:30:40.141002+00:00
- actor: claude-code
  id: 01m68hafxsty9mq8e70cf4h1xr
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, RouterSessionDirectoryInboxTests.swift, 2 fixture files
    - test: green — swift test, 2211 tests, 0 failures
    - commit: 3910cf9c
    - review: findings — RouterSessionDirectoryInboxTests.swift (aClosedSessionLeavesTheFile; mail-refusal path untested)
  timestamp: 2026-10-31T08:30:51.321814+00:00
- actor: claude-code
  id: 01m68hd3w3shwk7r93csa34fp7
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift. New test aRefusalOfTheMailLeavesTheFileAndStopsTheScan: a real session is closed, then put on the live list again with `directory.register`, so the scan reaches `hand` and `mail` throws MailRefusal.closed (the log shows error.type=MailRefusal). No stub is needed: RoutedSessionActor is the only RoutedSession conformer. The second file is unparseable and sorts last (z-later.md); a scan that reads it would move it to inbox/rejected. The old test is renamed aSessionThatIsNotLiveLeavesTheFile, and its doc comment names the not-live guard. The other doc comments in the file were checked; none overstates.
    - run: swift test --filter RouterSessionDirectoryInboxTests, 11 tests in 1 suite passed.
    - next: /review
  timestamp: 2026-10-31T08:32:17.283797+00:00
depends_on:
- 01M66VYQ268GZBRG3RDYPCZ0P2
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-10-31 03:32)

> Scope: `review sha HEAD~1..HEAD`. The engine reported 0 findings (0 confirmed, 1 refuted). The finding below comes from the check of the known gap against the Error rule and the acceptance criteria of this task.

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift` `aClosedSessionLeavesTheFile` — The Error rule of the task says: a `MailRefusal.closed` or another mail refusal is logged, the file stays in `inbox/`, and the scan stops. No test reaches this path. `target.close()` unregisters the session first, so `scanInbox` returns at `liveSession(id)` and never calls `hand(_:to:ledger:)`. The doc comment of the test says it fails when a scan "removes the file of a message that no mail carried", but the test passes even if the refusal branch of `deliverInboxFile` removes the file. Add a test where `hand` throws a mail refusal (for example, a stub `RoutedSession` registered in the directory whose `mail` throws `MailRefusal.closed`, with two files in the inbox). Expect: the first file stays, the ledger holds no message, the second file is not read, and the scan stops. Then correct the doc comment of `aClosedSessionLeavesTheFile` so it names the not-live guard that it tests.
