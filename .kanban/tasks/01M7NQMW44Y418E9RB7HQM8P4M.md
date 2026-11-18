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
- actor: claude-code
  id: 01m7qh98fk0pty5b5p7qafayp9
  text: |-
    Implementation notes.
    - Header format: the decision of the orchestrator overrides the example in the card. The prompt is `From the user, in <title> (<folder>)`, one blank line, then the text. The title is the short id when it is missing or empty. A source session that the directory does not know gives `From the user, in the session <ULID>`. This is the same as `SessionSenderHeader` of Extras. No ULID in the known-session line and no notice.
    - New type `UserMessageHeader` (Sources/FoundationModelsRouter/Directory/UserMessageHeader.swift). `send` makes it one time (`userHeader(of:recorded:)`): live summary of the source, else the recorded summaries that `send` already reads. The header goes through `deliver(toEach)` -> `deliver(to)` -> `deliverDirectly` -> `hand` -> `mail(...userHeader:)`, and through `startAgent` for the first mail of a started session. The inbox scan passes nil (inbox files have no source session; that is ^ty244es).
    - `Self.delivered(_ OutgoingSessionMessage...)` now sets `SessionMessage.sourceSession`, thus the ledger record and the `messageDelivered` event of the direct path and the agent-start path name the source. The full event work stays in ^jf3j3v5.
    - Discovery: an empty recorded title never reaches the header through the directory. `namingUntitled` gives each untitled recorded root a default name (an empty title reads back as nil). So the short-id case has a unit test on `UserMessageHeader` (UserMessageHeaderTests), not a directory test.
    - The test "no source session has no header" is the existing `RouterSessionDirectoryDeliveryTests.aSendToAnIdleSessionIsDeliveredAndAnswered` (prompt == text); it still passes. The archived test passed at RED, because the resolver refuses before delivery; it is a guard against a regression.
  timestamp: 2026-11-18T14:34:29.235191+00:00
- actor: claude-code
  id: 01m7qh9bmwqs5wakjh90fvycpm
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/UserMessageHeader.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift (new, 7 tests), Tests/FoundationModelsRouterTests/UserMessageHeaderTests.swift (new, 1 parameterized test). `swift test --filter "FoundationModelsRouterTests.RouterSessionDirectorySourceSessionTests|FoundationModelsRouterTests.UserMessageHeaderTests"`: 8 tests in 2 suites passed. Full `swift test`: 2890 tests in 336 suites passed, plus 48 tests in 26 suites and 19 tests in 3 suites passed; 0 failures; no compiler warnings (only the known SwiftPM "missing creator" note for the mlx bundle).
    - next: /review
  timestamp: 2026-11-18T14:34:32.476493+00:00
position_column: doing
position_ordinal: '80'
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

- [x] To an idle live target: one `.userMessage` mail, the prompt starts with the header line with the title and the folder of the source, the receipt is `delivered`, and a turn starts.
- [x] To a working target: the receipt is `queued`, and the message is delivered with the header when the turn ends.
- [x] A source session that is recorded and not live gives its recorded title and folder.
- [x] A user message with no source session has no header, as before.
- [x] To an archived target: refused with the reason `archived`. #d199