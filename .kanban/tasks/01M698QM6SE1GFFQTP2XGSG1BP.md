---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'Send to a recorded session that is not live: write the inbox file, never restore, receipt `sent`'
---
## What
A message to a session must not restore it. A send to a recorded session that is not live writes the file in the `inbox/` of the session and stops. The message is delivered later, when some host opens the session (the watcher then starts and its first scan delivers the file).

- `Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift`: replace the case `.restoreThenDeliver(ULID)` with `.sendToRecorded(ULID)` (line 24, and `reaching(session:)` at line 55). Update the doc comments. An archived session stays refused.
- `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: remove `restoreThenDeliver(_:chainDepth:to:)`, `restore(_:through:)` and the `restores` map. Add `sendToRecorded(_:chainDepth:to:)`: find the folder with `recordedFolder(of:)` (`SessionDirectoryError.unknownSession` when no root holds it), write the file with `writeInboxFile`, and return a receipt with the new outcome `sent` (the file is written, no delivery yet). The directory never calls the launcher for a send. `SessionDirectoryError.noLauncher` stays for `startAgent` only. Update the doc comments of `send(_:)` and the Throws lists.
- `SessionSendReceipt.Outcome` (public): add `sent`. Update every caller of the outcome in the same change, also in the packages that depend on it (the FoundationModelsMultitool `sessions` tool, `SessionsToolMessageOperations`): no deprecated alias, no old overload (see `ARCHITECTURE.md`).
- `mailbox-plan.md` says "`restoreThenDeliver`: write the file, then restore". Do not edit that file (it is untracked and not part of this change). Say in the final report that the line is now wrong.

## Acceptance Criteria
- [ ] `send(_:)` to a recorded session that is not live writes one file in its `inbox/`, returns the outcome `sent` with the id of the message, and never calls the launcher (a launcher that fails the test when it is called).
- [ ] The message is delivered when the session is registered later: the first scan of the watcher puts it in the ledger and starts the turn; the `messageDelivered` event follows.
- [ ] An archived session is still refused; a session id that no root holds still throws `unknownSession`.
- [ ] `restoreThenDeliver`, `restore(_:through:)` and `restores` are gone from the sources.

## Tests
- [ ] Update `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: replace the restore tests (`aRestoreDeliversTheFileItFinds`, the failed-restore test and similar) with: send to a recorded session writes a file and does not call the launcher; register the session later and the message is delivered. Wait on events, not on the clock.
- [ ] Update the other suites that expect a restore on send (find them with `rg "restoreSession|restoreThenDeliver" Tests`), and `SessionAddressResolution` tests.
- [ ] Run the filters for the suites you touch, then the full `swift test` once. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.