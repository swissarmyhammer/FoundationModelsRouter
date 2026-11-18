---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqpyc4efdgf8wp9mmjm9g0
  text: 'Extras task 01M7NQNHCZY77SHDX2H1969AEQ changes `InMemorySessionDirectory`: it does not restore a recorded target through the launcher, and it puts the message in the inbox, as the Router does. The Router tests do not use `InMemorySessionDirectory` today (no match in `Sources` or `Tests`). If a test that expects the restore fails after the Extras update, change the test to expect the inbox.'
  timestamp: 2026-11-17T21:48:20.228572+00:00
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
position_column: todo
position_ordinal: '8380'
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

- [ ] To a recorded target: one inbox file with the kind `user` and the source session; the receipt is `sent`.
- [ ] The scan at the next open delivers it as a user message with the header line.
- [ ] A user message with no source session to a recorded target is still refused with `userNeedsLiveSessionReason`.
- [ ] To an archived target: refused with the reason `archived`.
- [ ] An inbox file of the old format still reads as a session message. #d199