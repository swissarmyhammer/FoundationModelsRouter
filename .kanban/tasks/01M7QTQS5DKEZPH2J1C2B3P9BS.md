---
assignees:
- claude-code
depends_on:
- 01M7QTQCW62ZNN9CXFTVE3TV8Y
position_column: todo
position_ordinal: '8180'
title: An archive keeps the waiting mail as unread inbox messages (D204)
---
## Goal

An archive hides a session; it does not delete it. The mail that waits is kept. Decision D204 (`TestudoApp/features/decisions.md`, commit 9281f9c). Brief: `../.briefs/archive/router-brief.md`, item 2.

## Depends on

FoundationModelsExtras (the D204 change, see the unarchive task). The dependency on the unarchive task is for the test that archives, unarchives and opens a session.

## Current behavior

`archiveLive` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2794-2808`) calls `scanInbox(of:)` and then `session.cancelAll()` (`:2800`). The doc (`:2776-2779`) says that it "drops each waiting mail, also the mail of a message that waits for the end of the turn". Then it writes `archivedAt` with `updateRecord`, waits for the cancel, takes the session off the live list with `takeArchived` (`:2863-2876`, `forgetDeliveries` at `:2869`) and closes it.

## Change

- The running turn still ends cancelled.
- Each message that waits in the queue of the session, and each file of its `inbox/` folder, stays as an unread inbox message: a file in `inbox/` for a durable session.
- A message that goes from the queue to the inbox file keeps its sender, client id, source session and header (the inbox file format of ^ty244es).
- `messageDelivered` does not come for these messages at the archive. It comes when a client opens the session and takes them (the rule of ^jf3j3v5).
- A session that is not durable (no recording folder): write down what happens to its waiting mail, and test it.
- Change the doc of `archiveLive` (`:2776-2779`): an archive keeps the mail.
- The session actor code (`Session/RoutedSessionActor*.swift`, `MailFate.swift`) has pump and cancellation invariants. Read `routed-session-cancellation-invariants` in the memory folder before a change there.

## Tests

- [ ] Live session with a running turn and one queued message: archive, then unarchive, then restore with the launcher. The turn ended cancelled, and the queued message is in the inbox as unread and reaches the session when it opens.
- [ ] Inbox files that wait at the archive stay, and reach the session when it opens after an unarchive.
- [ ] No `messageDelivered` at the archive for a kept message.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d204