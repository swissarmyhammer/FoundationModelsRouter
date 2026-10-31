---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m699bjrcr26zbdk3a0bwqnt4
  text: |-
    ### implement - changed
    - A duplicate-id refusal (MailRefusal.duplicateID) now removes the file, logs a warning (session id, message id, file path), and the scan goes on. MailRefusal has only two cases: closed and duplicateID. closed and a ledger read error still keep the file and stop the scan. The doc comment of scanInbox states this.
    - Added LogMetadataKey.messageId (also in allKeys) in RouterTelemetry.swift.
    - New test aDuplicateMailIDIsRemovedAndTheScanGoesOn: red first (1 issue), then green. No clock waits.
    - evidence: swift test --filter RouterSessionDirectoryInboxTests: 25 tests passed. Build warnings in TranscriptEntryMapper.swift (switch must be exhaustive) were there before this work.
    - next: review
  timestamp: 2026-10-31T15:30:52.812643+00:00
position_column: doing
position_ordinal: '80'
title: 'Inbox scan: discard a duplicate-id file with a warning and keep scanning'
---
## What
In `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, change `deliverInboxFile` (the `return false` after a refusal of `hand(_:to:ledger:)`, about line 1214).

- A `MailRefusal.duplicateID` (the id is in the queue or in an open answer, but not in the ledger): remove the file, log a warning with `RouterTelemetry.makeLogger(.sessionDirectory)` (message id and file name in the metadata), and continue with the next file.
- Only `MailRefusal.closed` and a ledger read error stop the scan and keep the file. Any other refusal is handled by the same rule as `duplicateID` only if it can never succeed later; otherwise it stops the scan. State the choice in the doc comment.
- Update the doc comment of `scanInbox` (error rule).

## Acceptance Criteria
- [ ] A file with a duplicate mail id is removed, a warning is logged, and the files after it are delivered in the same scan.
- [ ] A closed session and a ledger read error still keep the file and stop the scan.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: two files, the first with a mail id that the queue holds already; the second is delivered; the first is gone. Wait on events, not on the clock.
- [ ] Run `swift test --filter RouterSessionDirectoryInboxTests`. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.