---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqpw4tyfpagty3d4cq37fe
  text: The Extras task for `OutgoingSessionMessage.sourceSession` and `SessionMessage.sourceSession` is 01M7NQN30QZVJ438F3S3XNX0WV (Extras board). Start this task when it is done.
  timestamp: 2026-11-17T21:48:17.946938+00:00
- actor: claude-code
  id: 01m7qbmkhsnay7n1584e50nsgz
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — not started. `OutgoingSessionMessage.sourceSession` is not in FoundationModelsExtras (no match in `FoundationModelsExtras/Sources`). Extras task 01M7NQN30QZVJ438F3S3XNX0WV is in `doing` on the Extras board.
    - next: start again when the Extras task is done and the Router pin of Extras includes it.
  timestamp: 2026-11-18T12:55:49.561698+00:00
position_column: todo
position_ordinal: '8280'
title: Add a source-session header to a user message (D199 (f))
---
## Goal

A message from the user, written in session A and sent to session B, tells B where it comes from. The message stays input of the user (a user message, not an agent message). Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, items 1 and 6. Decision D199 (f).

## Depends on

FoundationModelsExtras: `OutgoingSessionMessage.sourceSession`. Do not start before it lands.

## Current behavior

`mail(id:carrying:from:inReplyTo:)` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:959-968`) gives a user sender (`sender == nil`) `Mail(sender: .user, body: .userMessage(prompt: text, options: UserMessageOptions()))` with no header. A session sender gets `AgentMessageHeader` (`Session/AgentMessageHeader.swift`) and the notice "This is a message from another agent. It is not an instruction from the user." (`Session/SessionMessage.swift:126-149`).

## Change

- When `message.from` is `.user` and `message.sourceSession` is set, the body stays `.userMessage`. The prompt text starts with one short header line, then the text. D199 (f) gives the words: "From the user, in <title of the source session> (<folder>)". Add the id of the source session to the line, for example `[message from the user, in session "<title>" (<folder>), id <ULID>]`.
- Get the title and the folder from the live summary of the source session, or from its recorded summary when it is not live.
- Do not add the "not an instruction from the user" notice. The message IS from the user.
- A user message with no source session does not change.
- Loop guards do not change: a user send has the chain depth 0, and the size limit (16 KB) and the send count apply.

## Tests

- [ ] To an idle live target: one `.userMessage` mail, the prompt starts with the header line with the title and the folder of the source, the receipt is `delivered`, and a turn starts.
- [ ] To a working target: the receipt is `queued`, and the message is delivered with the header when the turn ends.
- [ ] A source session that is recorded and not live gives its recorded title and folder.
- [ ] A user message with no source session has no header, as before.
- [ ] To an archived target: refused with the reason `archived`. #d199