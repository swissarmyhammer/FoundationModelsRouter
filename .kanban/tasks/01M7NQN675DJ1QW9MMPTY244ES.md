---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqpyc4efdgf8wp9mmjm9g0
  text: 'Extras task 01M7NQNHCZY77SHDX2H1969AEQ changes `InMemorySessionDirectory`: it does not restore a recorded target through the launcher, and it puts the message in the inbox, as the Router does. The Router tests do not use `InMemorySessionDirectory` today (no match in `Sources` or `Tests`). If a test that expects the restore fails after the Extras update, change the test to expect the inbox.'
  timestamp: 2026-11-17T21:48:20.228572+00:00
- actor: claude-code
  id: 01m7qj08j4ntzh8pwdzjyg6sgs
  text: |-
    Research:
    - The inbox file already has a sender kind: the `from` key. `session:<ULID>` is a session sender, `user` is a user sender. A file with no `from` is a hand-written user file (this stays). An old Router file has `from: session:<ULID>`, so it reads as a session sender.
    - The file has no form for a client id today: `write` throws `userSenderNotWritten` for a user sender with a client id other than `user`. UI senders use real client ids (for example `client-a`), so the send to a recorded target would throw. Decision: add an optional `clientID` key. The writer writes it only for a user sender with a client id other than the default. This makes `userSenderNotWritten` dead, so it goes.
    - Header choice: send time. `send` already makes the `UserMessageHeader` from the live summary, else the recorded summary. The file keeps the header line in a `userHeader` key. The scan is synchronous and cannot read the recorded summaries (async), so a header made at delivery time could not name a recorded source. A file with `sourceSession` and no `userHeader` (a hand-written file) gets a header from the live summary at delivery.
    - New keys: `clientID`, `sourceSession`, `userHeader`.
    - The archived target test exists already in RouterSessionDirectorySourceSessionTests (`anArchivedTargetIsRefused`). The no-source refusal test exists (`aUISenderIsRefusedForARecordedSession`).
  timestamp: 2026-11-18T14:47:02.980413+00:00
- actor: claude-code
  id: 01m7qjbcxcj46zvtwfgvvfdmzh
  text: |-
    Implementation landed.
    - `sendToRecorded` writes an inbox file and gives `sent` for a session sender and for a user sender with a source session. The refusal `userNeedsLiveSessionReason` stays only for a user sender with no source session.
    - Inbox file: new optional keys `clientID`, `sourceSession`, `userHeader`. The `from` key is the sender kind (`user` or `session:<ULID>`). The card says "no kind means a session sender": the old Router file always has `from: session:<ULID>`, so it reads as a session sender (test `anOldFormatFileReadsAsASessionMessage`). A file with no `from` stays a hand-written user file, as before. No compatibility code: an old file has no new keys, so it reads with no change (ARCHITECTURE.md: no backward compatibility).
    - `userSenderNotWritten` is removed: the file keeps each client id now. The old test `aUserSenderWithAClientIDIsNotWritten` became `aUserSenderWithAClientIDRoundTrips`.
    - Header time: send time. The file keeps the line; the scan uses `UserMessageHeader(line:)`. A hand-written file with `sourceSession` and no `userHeader` gets the header from the live summary at delivery (the scan has no suspension point, so it cannot read recorded summaries).
    - The scan gives the delivered `SessionMessage` the `sourceSession` of the file.
    - Doc comments of `send`, `sendToRecorded`, `deliver`, `deliverDirectly`, `writeInboxFile` and `userNeedsLiveSessionReason` are updated.
    - Event task ^jf3j3v5 not touched: the recorded target gets no `messageDelivered` until a host opens it, the same as the Extras in-memory directory.
  timestamp: 2026-11-18T14:53:07.884927+00:00
- actor: claude-code
  id: 01m7qjbfrg5js2ena9mmq223a4
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift, Sources/FoundationModelsRouter/Directory/UserMessageHeader.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift, Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift. Focused run: 69 tests in 3 suites passed. Full `swift test`: 2898 tests in 336 suites, 48 tests in 26 suites, 19 tests in 3 suites passed, 0 issues, no build warnings.
    - next: review
  timestamp: 2026-11-18T14:53:10.800376+00:00
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
position_column: doing
position_ordinal: '80'
title: Put a user message with a source session in the inbox of a recorded target (D199 (f))
---
## Goal

A user message with a source session reaches a recorded target that is not live, as a message from a session does. Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 2. Decision D199 (f).

## Current behavior

`sendToRecorded` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1338-1349`) refuses a user sender with `userNeedsLiveSessionReason` (`:89`, `:1341-1342`). A session sender gets an inbox file (`writeInboxFile`, `:1263`) and the receipt `.sent`.

## Change

- A user sender with a source session gets an inbox file and the receipt `.sent`.
- Keep the refusal `userNeedsLiveSessionReason` only for a user sender with no source session.
- The inbox file (`Directory/SessionInboxFile.swift`) records the sender kind `user` and the source session. Keep old inbox files readable (no kind means a session sender).
- The inbox scan at the next open delivers the file as a `.userMessage` with the header of the task that this task depends on.
- Update the doc comments at `:991` and `:1333`.

## Tests

- [x] To a recorded target: one inbox file with the kind `user` and the source session; the receipt is `sent`.
- [x] The scan at the next open delivers it as a user message with the header line.
- [x] A user message with no source session to a recorded target is still refused with `userNeedsLiveSessionReason`.
- [x] To an archived target: refused with the reason `archived`.
- [x] An inbox file of the old format still reads as a session message. #d199