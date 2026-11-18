---
assignees:
- claude-code
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
- 01M7NQN675DJ1QW9MMPTY244ES
position_column: todo
position_ordinal: '8480'
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