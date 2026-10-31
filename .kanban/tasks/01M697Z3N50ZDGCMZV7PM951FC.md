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
- actor: claude-code
  id: 01m699rtt3xk8fs43awvfm4jw9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~2..HEAD (4ff41b28, cf0103a8): 2 findings, 2 confirmed, 3 refuted. RouterSessionDirectory.swift:1288 (reuse/reuse), TranscriptEntryMapperTests.swift:798 (swift/optionals).
    - next: fix both items, then run /review again.
  timestamp: 2026-10-31T15:38:07.043950+00:00
- actor: claude-code
  id: 01m699s6z1n3kce13qxy6e896p
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, RouterTelemetry.swift, RouterSessionDirectoryInboxTests.swift
    - test: green — swift test, 2170 tests, 0 failures (also fixed the .data switch warning in TranscriptEntryMapper)
    - commit: 4ff41b28, cf0103a8
    - review: findings — RouterSessionDirectory.swift:1288, TranscriptEntryMapperTests.swift:798
  timestamp: 2026-10-31T15:38:19.489114+00:00
- actor: claude-code
  id: 01m699xcywskh5xa5gxw1a7syv
  text: |-
    ### implement — changed
    - evidence: RouterSessionDirectory.swift: logInboxFailure and logInboxDuplicate now call one helper logInbox(level, what, session, file, metadata) that adds the session id and file path; added import Logging. TranscriptEntryMapperTests.swift: the data-entry test uses try #require plus if case / Issue.record, no guard. Other tests touched by the two commits had no guard (inbox tests: none). swift test --filter 'RouterSessionDirectoryInboxTests|TranscriptEntryMapperTests': 70 tests in 2 suites passed.
    - next: review
  timestamp: 2026-10-31T15:40:36.700587+00:00
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

## Review Findings (2026-10-31 10:36)

> Scope: `review sha HEAD~2..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 12 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1288` `reuse/reuse` — logInboxDuplicate repeats the structure of the existing logInboxFailure. Both build a RouterTelemetry logger for .sessionDirectory and add the session id and file path to the metadata. Only the level, the message and one extra key differ. A second function for this pattern makes two places to change the log shape. Extend logInboxFailure so it takes the log level and the extra metadata as parameters, or move the shared metadata (sessionId and filePath) into a small helper that both functions call. Keep the warning text at the call site.
- [x] `Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift:798` `swift/optionals` — The new test uses `guard case .unknown(let id, _) = event.payload.segments?.first else { Issue.record(...); return }`. The `return` ends the test before the later assertions run, so a failed unwrap returns early instead of stopping the test with a clear failure. The rule says a test must not use `guard`. Replace the guard with `let segment = try #require(event.payload.segments?.first)`, then assert the case with `#expect`, for example `if case .unknown(let id, _) = segment { #expect(id == "d1") } else { Issue.record("expected the data entry to record as the unknown segment carrier") }`. The `Issue.record` in the else branch fails the test, so the test cannot pass silently.
